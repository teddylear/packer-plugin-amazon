package sshrelaybench

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	mathrand "math/rand"
	"net"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/hashicorp/packer-plugin-sdk/communicator"
	"github.com/hashicorp/packer-plugin-sdk/multistep"
	packersdk "github.com/hashicorp/packer-plugin-sdk/packer"
	"github.com/hashicorp/packer-plugin-sdk/template/interpolate"
	gossh "golang.org/x/crypto/ssh"
)

const outputPrefix = "relay-line"

const (
	targetModeDocker    = "docker"
	targetModeInProcess = "inprocess"
	dockerImage         = "lscr.io/linuxserver/openssh-server:latest"
	proxyModeLatency    = "latency"
	proxyModeNone       = "none"
	tcpNoDelayDefault   = "default"
	tcpNoDelayFalse     = "false"
	tcpNoDelayTrue      = "true"
)

type relayConfig struct {
	Lines         int
	PayloadBytes  int
	ChunkBytes    int
	InterLineWait time.Duration
	Command       string
}

type relayMetrics struct {
	ConnectDurationMillis float64 `json:"connect_duration_ms"`
	RunDurationMillis     float64 `json:"run_duration_ms"`
	TotalDurationMillis   float64 `json:"total_duration_ms"`
	FirstLineMillis       float64 `json:"first_line_ms"`
	MedianGapMillis       float64 `json:"median_gap_ms"`
	P95GapMillis          float64 `json:"p95_gap_ms"`
	MaxGapMillis          float64 `json:"max_gap_ms"`
	Lines                 int     `json:"lines"`
	ExitStatus            int     `json:"exit_status"`
	ErrorMessages         int     `json:"error_messages"`
}

type timedMessage struct {
	text string
	at   time.Time
}

type timedUI struct {
	mu     sync.Mutex
	says   []timedMessage
	errors []timedMessage
	packersdk.NoopProgressTracker
}

func (u *timedUI) Ask(string) (string, error)          { return "", fmt.Errorf("Ask is unsupported") }
func (u *timedUI) Askf(string, ...any) (string, error) { return "", fmt.Errorf("Askf is unsupported") }
func (u *timedUI) Sayf(format string, args ...any)     { u.Say(fmt.Sprintf(format, args...)) }
func (u *timedUI) Message(message string)              { u.Say(message) }
func (u *timedUI) Errorf(format string, args ...any)   { u.Error(fmt.Sprintf(format, args...)) }
func (u *timedUI) Machine(string, ...string)           {}
func (u *timedUI) TrackProgress(_ string, _, _ int64, stream io.ReadCloser) io.ReadCloser {
	return stream
}

func (u *timedUI) Say(message string) {
	u.mu.Lock()
	defer u.mu.Unlock()
	u.says = append(u.says, timedMessage{text: message, at: time.Now()})
}

func (u *timedUI) Error(message string) {
	u.mu.Lock()
	defer u.mu.Unlock()
	u.errors = append(u.errors, timedMessage{text: message, at: time.Now()})
}

func (u *timedUI) snapshot() ([]timedMessage, []timedMessage) {
	u.mu.Lock()
	defer u.mu.Unlock()
	says := append([]timedMessage(nil), u.says...)
	errs := append([]timedMessage(nil), u.errors...)
	return says, errs
}

type localSSHServer struct {
	listener  net.Listener
	host      string
	port      int
	user      string
	clientPEM []byte
	config    relayConfig
	ready     chan struct{}
	serveErr  chan error
	closeOnce sync.Once
	acceptWG  sync.WaitGroup
}

type relayTarget struct {
	host      string
	port      int
	user      string
	clientPEM []byte
	close     func() error
}

type latencyProxy struct {
	listener   net.Listener
	targetHost string
	targetPort int
	latency    time.Duration
	jitter     time.Duration
	tcpNoDelay string
	rngMu      sync.Mutex
	rng        *mathrand.Rand
	connsMu    sync.Mutex
	conns      map[net.Conn]struct{}
	closeOnce  sync.Once
	acceptWG   sync.WaitGroup
	errCh      chan error
}

func TestRelayMetrics(t *testing.T) {
	metrics := runRelay(t, relayConfigFromEnv())
	metricsJSON, err := json.Marshal(metrics)
	if err != nil {
		t.Fatalf("marshal metrics: %v", err)
	}
	t.Logf("relay metrics: %s", metricsJSON)
}

func BenchmarkRelay(b *testing.B) {
	config := relayConfigFromEnv()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		metrics := runRelay(b, config)
		if metrics.Lines != config.Lines {
			b.Fatalf("got %d lines, want %d", metrics.Lines, config.Lines)
		}
	}
}

func runRelay(tb testing.TB, config relayConfig) relayMetrics {
	tb.Helper()

	target := startRelayTarget(tb, config)
	defer func() {
		if err := target.close(); err != nil {
			tb.Errorf("cleanup relay target: %v", err)
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), relayTimeoutFromEnv())
	defer cancel()

	ui := &timedUI{}
	commConfig := &communicator.Config{
		Type: "ssh",
		SSH: communicator.SSH{
			SSHUsername:               target.user,
			SSHPrivateKey:             target.clientPEM,
			SSHTimeout:                5 * time.Second,
			SSHHandshakeAttempts:      1,
			SSHDisableAgentForwarding: true,
			SSHKeepAliveInterval:      -1 * time.Second,
			SSHFileTransferMethod:     "scp",
		},
	}
	if kexOverride := kexOverrideFromEnv(); len(kexOverride) > 0 {
		commConfig.SSH.SSHKEXAlgos = kexOverride
	}
	if cipherOverride := cipherOverrideFromEnv(); len(cipherOverride) > 0 {
		commConfig.SSH.SSHCiphers = cipherOverride
	}

	if errs := commConfig.Prepare(&interpolate.Context{}); len(errs) > 0 {
		messages := make([]string, 0, len(errs))
		for _, err := range errs {
			messages = append(messages, err.Error())
		}
		tb.Fatalf("prepare communicator config: %s", strings.Join(messages, "; "))
	}

	state := &multistep.BasicStateBag{}
	state.Put("ui", ui)

	step := &communicator.StepConnectSSH{
		Config: commConfig,
		Host: func(multistep.StateBag) (string, error) {
			return target.host, nil
		},
		SSHPort: func(multistep.StateBag) (int, error) {
			return target.port, nil
		},
		SSHConfig: commConfig.SSHConfigFunc(),
	}

	totalStart := time.Now()
	connectStart := time.Now()
	if action := step.Run(ctx, state); action != multistep.ActionContinue {
		tb.Fatalf("connect step halted: %#v", state.Get("error"))
	}
	connectDuration := time.Since(connectStart)

	comm, ok := state.GetOk("communicator")
	if !ok {
		tb.Fatal("communicator missing from state")
	}

	cmd := &packersdk.RemoteCmd{Command: commandForTarget(config)}
	runStart := time.Now()
	if err := cmd.RunWithUi(ctx, comm.(packersdk.Communicator), ui); err != nil {
		tb.Fatalf("run command: %v", err)
	}
	runDuration := time.Since(runStart)
	totalDuration := time.Since(totalStart)

	metrics := buildMetrics(ui, runStart, connectDuration, runDuration, totalDuration, cmd.ExitStatus())
	if metrics.Lines != config.Lines {
		says, errs := ui.snapshot()
		tb.Fatalf("got %d lines, want %d; ui says=%q ui errors=%q", metrics.Lines, config.Lines, messageTexts(says, 8), messageTexts(errs, 8))
	}
	if metrics.ExitStatus != 0 {
		tb.Fatalf("unexpected exit status %d", metrics.ExitStatus)
	}
	if metrics.ErrorMessages != 0 {
		tb.Fatalf("unexpected ui errors: %d", metrics.ErrorMessages)
	}

	return metrics
}

func buildMetrics(ui *timedUI, runStart time.Time, connectDuration, runDuration, totalDuration time.Duration, exitStatus int) relayMetrics {
	says, errs := ui.snapshot()
	lineTimes := make([]time.Time, 0, len(says))
	for _, message := range says {
		if strings.HasPrefix(message.text, outputPrefix+" ") {
			lineTimes = append(lineTimes, message.at)
		}
	}

	gapCapacity := 0
	if len(lineTimes) > 1 {
		gapCapacity = len(lineTimes) - 1
	}
	gaps := make([]time.Duration, 0, gapCapacity)
	for i := 1; i < len(lineTimes); i++ {
		gaps = append(gaps, lineTimes[i].Sub(lineTimes[i-1]))
	}

	metrics := relayMetrics{
		ConnectDurationMillis: durationMillis(connectDuration),
		RunDurationMillis:     durationMillis(runDuration),
		TotalDurationMillis:   durationMillis(totalDuration),
		Lines:                 len(lineTimes),
		ExitStatus:            exitStatus,
		ErrorMessages:         len(errs),
	}
	if len(lineTimes) > 0 {
		metrics.FirstLineMillis = durationMillis(lineTimes[0].Sub(runStart))
	}
	if len(gaps) > 0 {
		sorted := append([]time.Duration(nil), gaps...)
		sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
		metrics.MedianGapMillis = durationMillis(percentileDuration(sorted, 0.5))
		metrics.P95GapMillis = durationMillis(percentileDuration(sorted, 0.95))
		metrics.MaxGapMillis = durationMillis(sorted[len(sorted)-1])
	}

	return metrics
}

func messageTexts(messages []timedMessage, limit int) []string {
	if limit > len(messages) {
		limit = len(messages)
	}
	texts := make([]string, 0, limit)
	for i := 0; i < limit; i++ {
		texts = append(texts, messages[i].text)
	}
	return texts
}

func percentileDuration(values []time.Duration, percentile float64) time.Duration {
	if len(values) == 0 {
		return 0
	}
	if percentile <= 0 {
		return values[0]
	}
	if percentile >= 1 {
		return values[len(values)-1]
	}
	index := int(percentile * float64(len(values)-1))
	return values[index]
}

func relayConfigFromEnv() relayConfig {
	config := relayConfig{
		Lines:        envInt("SSHRELAYBENCH_LINES", 1050),
		PayloadBytes: envInt("SSHRELAYBENCH_PAYLOAD_BYTES", 64),
		ChunkBytes:   envInt("SSHRELAYBENCH_CHUNK_BYTES", 0),
		Command:      envString("SSHRELAYBENCH_COMMAND", "relay"),
	}
	config.InterLineWait = envDuration("SSHRELAYBENCH_INTER_LINE_WAIT", 0)
	return config
}

func targetModeFromEnv() string {
	mode := strings.TrimSpace(os.Getenv("SSHRELAYBENCH_TARGET"))
	if mode == "" {
		return targetModeInProcess
	}
	return strings.ToLower(mode)
}

func proxyModeFromEnv() string {
	mode := strings.TrimSpace(os.Getenv("SSHRELAYBENCH_PROXY"))
	if mode == "" {
		return proxyModeNone
	}
	return strings.ToLower(mode)
}

func tcpNoDelayFromEnv() string {
	mode := strings.TrimSpace(os.Getenv("SSHRELAYBENCH_TCP_NODELAY"))
	if mode == "" {
		return tcpNoDelayDefault
	}
	return strings.ToLower(mode)
}

func kexOverrideFromEnv() []string {
	return envList("SSHRELAYBENCH_FORCE_KEX")
}

func cipherOverrideFromEnv() []string {
	return envList("SSHRELAYBENCH_FORCE_CIPHERS")
}

func relayTimeoutFromEnv() time.Duration {
	return envDuration("SSHRELAYBENCH_TIMEOUT", 30*time.Second)
}

func envInt(name string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func envDuration(name string, fallback time.Duration) time.Duration {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return fallback
	}
	return parsed
}

func envString(name string, fallback string) string {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	return value
}

func envList(name string) []string {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func durationMillis(value time.Duration) float64 {
	return float64(value) / float64(time.Millisecond)
}

func startRelayTarget(tb testing.TB, config relayConfig) relayTarget {
	tb.Helper()

	var base relayTarget
	switch targetModeFromEnv() {
	case targetModeDocker:
		base = startDockerRelayTarget(tb, config)
	case targetModeInProcess:
		base = startInProcessRelayTarget(tb, config)
	default:
		tb.Fatalf("unknown SSHRELAYBENCH_TARGET %q", targetModeFromEnv())
		return relayTarget{}
	}

	if proxyModeFromEnv() != proxyModeLatency {
		return base
	}

	proxy := startLatencyProxy(tb, base.host, base.port, envDuration("SSHRELAYBENCH_LATENCY", 0), envDuration("SSHRELAYBENCH_JITTER", 0), tcpNoDelayFromEnv())
	return relayTarget{
		host:      "127.0.0.1",
		port:      proxy.port(),
		user:      base.user,
		clientPEM: base.clientPEM,
		close: func() error {
			proxyErr := proxy.Close()
			baseErr := base.close()
			if proxyErr != nil {
				return proxyErr
			}
			return baseErr
		},
	}
}

func startInProcessRelayTarget(tb testing.TB, config relayConfig) relayTarget {
	tb.Helper()

	server := startLocalSSHServer(tb, config)
	return relayTarget{
		host:      server.host,
		port:      server.port,
		user:      server.user,
		clientPEM: server.clientPEM,
		close: func() error {
			server.Close()
			return nil
		},
	}
}

func startDockerRelayTarget(tb testing.TB, config relayConfig) relayTarget {
	tb.Helper()

	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		tb.Fatalf("generate docker client key: %v", err)
	}

	pkcs8Key, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		tb.Fatalf("marshal docker client key: %v", err)
	}

	privateKeyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: pkcs8Key})
	signer, err := gossh.ParsePrivateKey(privateKeyPEM)
	if err != nil {
		tb.Fatalf("parse docker client key: %v", err)
	}
	publicKey := strings.TrimSpace(string(gossh.MarshalAuthorizedKey(signer.PublicKey())))

	configDir, err := os.MkdirTemp("", "sshrelaybench-docker-config-")
	if err != nil {
		tb.Fatalf("create docker config dir: %v", err)
	}

	containerName := fmt.Sprintf("sshrelaybench-%d", time.Now().UnixNano())
	runArgs := []string{
		"run", "-d", "--rm",
		"--name", containerName,
		"-p", "127.0.0.1::2222",
		"-e", fmt.Sprintf("PUID=%d", os.Getuid()),
		"-e", fmt.Sprintf("PGID=%d", os.Getgid()),
		"-e", "TZ=Etc/UTC",
		"-e", "USER_NAME=packer",
		"-e", "PASSWORD_ACCESS=false",
		"-e", "SUDO_ACCESS=false",
		"-e", "LOG_STDOUT=true",
		"-e", "PUBLIC_KEY=" + publicKey,
		"-v", configDir + ":/config",
		dockerImage,
	}

	if output, err := exec.Command("docker", runArgs...).CombinedOutput(); err != nil {
		os.RemoveAll(configDir)
		tb.Fatalf("start docker relay target: %v\n%s", err, output)
	}

	port, err := dockerMappedPort(containerName)
	if err != nil {
		_ = dockerForceRemove(containerName)
		os.RemoveAll(configDir)
		tb.Fatalf("inspect docker port: %v", err)
	}

	if err := waitForDockerSSH("127.0.0.1", port, "packer", privateKeyPEM, 30*time.Second); err != nil {
		logs, _ := dockerLogs(containerName)
		_ = dockerForceRemove(containerName)
		os.RemoveAll(configDir)
		tb.Fatalf("wait for docker ssh: %v\nlogs:\n%s", err, logs)
	}

	return relayTarget{
		host:      "127.0.0.1",
		port:      port,
		user:      "packer",
		clientPEM: privateKeyPEM,
		close: func() error {
			removeErr := dockerForceRemove(containerName)
			cleanupErr := os.RemoveAll(configDir)
			if removeErr != nil {
				return removeErr
			}
			return cleanupErr
		},
	}
}

func startLatencyProxy(tb testing.TB, targetHost string, targetPort int, latency time.Duration, jitter time.Duration, tcpNoDelay string) *latencyProxy {
	tb.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		tb.Fatalf("listen latency proxy: %v", err)
	}

	proxy := &latencyProxy{
		listener:   listener,
		targetHost: targetHost,
		targetPort: targetPort,
		latency:    latency,
		jitter:     jitter,
		tcpNoDelay: tcpNoDelay,
		rng:        mathrand.New(mathrand.NewSource(time.Now().UnixNano())),
		conns:      make(map[net.Conn]struct{}),
		errCh:      make(chan error, 1),
	}

	proxy.acceptWG.Add(1)
	go func() {
		defer proxy.acceptWG.Done()
		for {
			clientConn, err := listener.Accept()
			if err != nil {
				if errorsIsNetClosed(err) {
					return
				}
				proxy.reportErr(err)
				return
			}

			proxy.acceptWG.Add(1)
			go func() {
				defer proxy.acceptWG.Done()
				if err := proxy.handleConn(clientConn); err != nil && !isExpectedProbeError(err) && !errorsIsNetClosed(err) {
					proxy.reportErr(err)
				}
			}()
		}
	}()

	return proxy
}

func (p *latencyProxy) port() int {
	_, portString, err := net.SplitHostPort(p.listener.Addr().String())
	if err != nil {
		return 0
	}
	port, err := strconv.Atoi(portString)
	if err != nil {
		return 0
	}
	return port
}

func (p *latencyProxy) reportErr(err error) {
	select {
	case p.errCh <- err:
	default:
	}
}

func (p *latencyProxy) Close() error {
	p.closeOnce.Do(func() {
		_ = p.listener.Close()
		p.closeActiveConns()
		p.acceptWG.Wait()
	})
	select {
	case err := <-p.errCh:
		return err
	default:
		return nil
	}
}

func (p *latencyProxy) trackConn(conn net.Conn) {
	p.connsMu.Lock()
	p.conns[conn] = struct{}{}
	p.connsMu.Unlock()
}

func (p *latencyProxy) untrackConn(conn net.Conn) {
	p.connsMu.Lock()
	delete(p.conns, conn)
	p.connsMu.Unlock()
}

func (p *latencyProxy) closeActiveConns() {
	p.connsMu.Lock()
	defer p.connsMu.Unlock()
	for conn := range p.conns {
		_ = conn.Close()
	}
}

func (p *latencyProxy) handleConn(clientConn net.Conn) error {
	defer clientConn.Close()
	p.trackConn(clientConn)
	defer p.untrackConn(clientConn)
	address := net.JoinHostPort(p.targetHost, strconv.Itoa(p.targetPort))
	targetConn, err := net.DialTimeout("tcp", address, 5*time.Second)
	if err != nil {
		return err
	}
	defer targetConn.Close()
	p.trackConn(targetConn)
	defer p.untrackConn(targetConn)

	applyTCPNoDelay(clientConn, p.tcpNoDelay)
	applyTCPNoDelay(targetConn, p.tcpNoDelay)

	errCh := make(chan error, 2)
	go p.copyWithDelay(errCh, targetConn, clientConn)
	go p.copyWithDelay(errCh, clientConn, targetConn)

	firstErr := <-errCh
	_ = clientConn.SetDeadline(time.Now())
	_ = targetConn.SetDeadline(time.Now())
	secondErr := <-errCh

	if !isIgnorableProxyError(firstErr) {
		return firstErr
	}
	if !isIgnorableProxyError(secondErr) {
		return secondErr
	}
	return nil
}

func (p *latencyProxy) copyWithDelay(errCh chan<- error, dst net.Conn, src net.Conn) {
	buf := make([]byte, 64*1024)
	for {
		n, err := readBatch(src, buf)
		if n > 0 {
			p.sleepDelay()
			if _, writeErr := dst.Write(buf[:n]); writeErr != nil {
				errCh <- writeErr
				return
			}
		}
		if err != nil {
			errCh <- err
			return
		}
	}
}

func readBatch(conn net.Conn, buf []byte) (int, error) {
	total, err := conn.Read(buf)
	if total == 0 || err != nil {
		return total, err
	}

	for total < len(buf) {
		_ = conn.SetReadDeadline(time.Now().Add(1 * time.Millisecond))
		n, readErr := conn.Read(buf[total:])
		total += n
		if readErr != nil {
			_ = conn.SetReadDeadline(time.Time{})
			if netErr, ok := readErr.(net.Error); ok && netErr.Timeout() {
				return total, nil
			}
			return total, readErr
		}
	}

	_ = conn.SetReadDeadline(time.Time{})
	return total, nil
}

func (p *latencyProxy) sleepDelay() {
	delay := p.latency
	if p.jitter > 0 {
		spread := p.jitter * 2
		p.rngMu.Lock()
		jitterOffset := time.Duration(p.rng.Int63n(int64(spread)+1)) - p.jitter
		p.rngMu.Unlock()
		delay += jitterOffset
	}
	if delay > 0 {
		time.Sleep(delay)
	}
}

func applyTCPNoDelay(conn net.Conn, mode string) {
	tcpConn, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	switch mode {
	case tcpNoDelayTrue:
		_ = tcpConn.SetNoDelay(true)
	case tcpNoDelayFalse:
		_ = tcpConn.SetNoDelay(false)
	}
}

func isIgnorableProxyError(err error) bool {
	if err == nil || errors.Is(err, io.EOF) {
		return true
	}
	errText := err.Error()
	return strings.Contains(errText, "use of closed network connection") ||
		strings.Contains(errText, "broken pipe") ||
		strings.Contains(errText, "connection reset by peer") ||
		strings.Contains(errText, "i/o timeout")
}

func startLocalSSHServer(tb testing.TB, config relayConfig) *localSSHServer {
	tb.Helper()

	hostSigner, _, err := generateSigner()
	if err != nil {
		tb.Fatalf("generate host signer: %v", err)
	}
	clientSigner, clientPEM, err := generateSigner()
	if err != nil {
		tb.Fatalf("generate client signer: %v", err)
	}

	serverConfig := &gossh.ServerConfig{
		PublicKeyCallback: func(conn gossh.ConnMetadata, key gossh.PublicKey) (*gossh.Permissions, error) {
			if conn.User() != "packer" {
				return nil, fmt.Errorf("unexpected user %q", conn.User())
			}
			if !bytes.Equal(key.Marshal(), clientSigner.PublicKey().Marshal()) {
				return nil, fmt.Errorf("unexpected client key")
			}
			return nil, nil
		},
	}
	serverConfig.AddHostKey(hostSigner)

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		tb.Fatalf("listen: %v", err)
	}

	host, portString, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		listener.Close()
		tb.Fatalf("split host port: %v", err)
	}
	port, err := strconv.Atoi(portString)
	if err != nil {
		listener.Close()
		tb.Fatalf("parse port %q: %v", portString, err)
	}

	server := &localSSHServer{
		listener:  listener,
		host:      host,
		port:      port,
		user:      "packer",
		clientPEM: clientPEM,
		config:    config,
		ready:     make(chan struct{}),
		serveErr:  make(chan error, 1),
	}

	server.acceptWG.Add(1)
	go func() {
		defer server.acceptWG.Done()
		close(server.ready)
		for {
			netConn, err := listener.Accept()
			if err != nil {
				if errorsIsNetClosed(err) {
					return
				}
				server.serveErr <- err
				return
			}

			if err := server.serveConn(netConn, serverConfig); err != nil {
				if isExpectedProbeError(err) {
					continue
				}
				server.serveErr <- err
				return
			}

			return
		}
	}()

	<-server.ready
	return server
}

func (s *localSSHServer) Close() {
	s.closeOnce.Do(func() {
		s.listener.Close()
		s.acceptWG.Wait()
	})
}

func commandForTarget(config relayConfig) string {
	if targetModeFromEnv() != targetModeDocker {
		return config.Command
	}
	if config.Command != "" && config.Command != "relay" {
		return config.Command
	}
	return dockerRelayCommand(config)
}

func dockerRelayCommand(config relayConfig) string {
	payload := strings.Repeat("x", config.PayloadBytes)
	command := fmt.Sprintf("i=0; while [ \"$i\" -lt %d ]; do printf '%%s %%06d %%s\\n' '%s' \"$i\" '%s'; i=$((i+1)); done", config.Lines, outputPrefix, payload)
	if config.InterLineWait > 0 {
		command = fmt.Sprintf("i=0; while [ \"$i\" -lt %d ]; do printf '%%s %%06d %%s\\n' '%s' \"$i\" '%s'; sleep %0.6f; i=$((i+1)); done", config.Lines, outputPrefix, payload, config.InterLineWait.Seconds())
	}
	return command
}

func (s *localSSHServer) serveConn(netConn net.Conn, config *gossh.ServerConfig) error {
	defer netConn.Close()

	serverConn, channels, requests, err := gossh.NewServerConn(netConn, config)
	if err != nil {
		return err
	}
	defer serverConn.Close()
	go gossh.DiscardRequests(requests)

	for newChannel := range channels {
		if newChannel.ChannelType() != "session" {
			if rejectErr := newChannel.Reject(gossh.UnknownChannelType, "only session channels are supported"); rejectErr != nil {
				return rejectErr
			}
			continue
		}

		if err := s.serveSession(newChannel); err != nil {
			return err
		}
		return nil
	}

	return nil
}

func (s *localSSHServer) serveSession(newChannel gossh.NewChannel) error {
	channel, requests, err := newChannel.Accept()
	if err != nil {
		return err
	}
	defer channel.Close()

	for request := range requests {
		switch request.Type {
		case "exec":
			if request.WantReply {
				if err := request.Reply(true, nil); err != nil {
					return err
				}
			}
			return s.writeRelayOutput(channel)
		case "keepalive@packer.io":
			if request.WantReply {
				if err := request.Reply(true, nil); err != nil {
					return err
				}
			}
		default:
			if request.WantReply {
				if err := request.Reply(false, nil); err != nil {
					return err
				}
			}
		}
	}

	return nil
}

func (s *localSSHServer) writeRelayOutput(channel gossh.Channel) error {
	payload := strings.Repeat("x", s.config.PayloadBytes)
	for i := 0; i < s.config.Lines; i++ {
		line := fmt.Sprintf("%s %06d %s\n", outputPrefix, i, payload)
		if err := writeInChunks(channel, []byte(line), s.config.ChunkBytes); err != nil {
			return err
		}
		if s.config.InterLineWait > 0 {
			time.Sleep(s.config.InterLineWait)
		}
	}

	status := struct {
		Status uint32
	}{Status: 0}
	_, err := channel.SendRequest("exit-status", false, gossh.Marshal(&status))
	return err
}

func writeInChunks(writer io.Writer, payload []byte, chunkBytes int) error {
	if chunkBytes <= 0 || chunkBytes >= len(payload) {
		_, err := writer.Write(payload)
		return err
	}

	for len(payload) > 0 {
		chunkSize := chunkBytes
		if chunkSize > len(payload) {
			chunkSize = len(payload)
		}
		if _, err := writer.Write(payload[:chunkSize]); err != nil {
			return err
		}
		payload = payload[chunkSize:]
	}

	return nil
}

func generateSigner() (gossh.Signer, []byte, error) {
	_, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, nil, err
	}

	pkcs8Key, err := x509.MarshalPKCS8PrivateKey(privateKey)
	if err != nil {
		return nil, nil, err
	}

	privateKeyPEM := pem.EncodeToMemory(&pem.Block{
		Type:  "PRIVATE KEY",
		Bytes: pkcs8Key,
	})

	signer, err := gossh.ParsePrivateKey(privateKeyPEM)
	if err != nil {
		return nil, nil, err
	}

	return signer, privateKeyPEM, nil
}

func errorsIsNetClosed(err error) bool {
	return strings.Contains(err.Error(), "use of closed network connection")
}

func isExpectedProbeError(err error) bool {
	if errors.Is(err, io.EOF) {
		return true
	}
	errText := err.Error()
	return strings.Contains(errText, "connection reset by peer") ||
		strings.Contains(errText, "failed to read version") ||
		strings.Contains(errText, "EOF")
}

func dockerMappedPort(containerName string) (int, error) {
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		output, err := exec.Command("docker", "port", containerName, "2222/tcp").CombinedOutput()
		if err == nil {
			mapping := strings.TrimSpace(string(output))
			_, portString, splitErr := net.SplitHostPort(mapping)
			if splitErr == nil {
				port, convErr := strconv.Atoi(portString)
				if convErr == nil {
					return port, nil
				}
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return 0, fmt.Errorf("docker port for %s did not become available", containerName)
}

func waitForDockerSSH(host string, port int, user string, privateKeyPEM []byte, timeout time.Duration) error {
	signer, err := gossh.ParsePrivateKey(privateKeyPEM)
	if err != nil {
		return err
	}
	config := &gossh.ClientConfig{
		User:            user,
		HostKeyCallback: gossh.InsecureIgnoreHostKey(),
		Auth:            []gossh.AuthMethod{gossh.PublicKeys(signer)},
		Timeout:         2 * time.Second,
	}

	deadline := time.Now().Add(timeout)
	address := net.JoinHostPort(host, strconv.Itoa(port))
	for time.Now().Before(deadline) {
		client, err := gossh.Dial("tcp", address, config)
		if err == nil {
			client.Close()
			return nil
		}
		time.Sleep(250 * time.Millisecond)
	}
	return fmt.Errorf("ssh did not become ready within %s", timeout)
}

func dockerForceRemove(containerName string) error {
	output, err := exec.Command("docker", "rm", "-f", containerName).CombinedOutput()
	if err != nil {
		if strings.Contains(string(output), "No such container") {
			return nil
		}
		return fmt.Errorf("docker rm -f %s: %w\n%s", containerName, err, output)
	}
	return nil
}

func dockerLogs(containerName string) (string, error) {
	output, err := exec.Command("docker", "logs", containerName).CombinedOutput()
	if err != nil {
		return string(output), err
	}
	return string(output), nil
}
