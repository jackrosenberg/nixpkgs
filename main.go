package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/fosrl/gerbil/logger"
	"github.com/vishvananda/netlink"
	"golang.zx2c4.com/wireguard/wgctrl"
	"golang.zx2c4.com/wireguard/wgctrl/wgtypes"
)

var (
	interfaceName string
	listenAddr    string
	mtuInt        int
	lastReadings  = make(map[string]PeerReading)
	mu            sync.Mutex
)

type WgConfig struct {
	PrivateKey string `json:"privateKey"`
	ListenPort int    `json:"listenPort"`
	IpAddress  string `json:"ipAddress"`
	Peers      []Peer `json:"peers"`
}

type Peer struct {
	PublicKey  string   `json:"publicKey"`
	AllowedIPs []string `json:"allowedIps"`
}

type PeerBandwidth struct {
	PublicKey string  `json:"publicKey"`
	BytesIn   float64 `json:"bytesIn"`
	BytesOut  float64 `json:"bytesOut"`
}

type PeerReading struct {
	BytesReceived    int64
	BytesTransmitted int64
	LastChecked      time.Time
}

var (
	wgClient *wgctrl.Client
)

func parseLogLevel(level string) logger.LogLevel {
	switch strings.ToUpper(level) {
	case "DEBUG":
		return logger.DEBUG
	case "INFO":
		return logger.INFO
	case "WARN":
		return logger.WARN
	case "ERROR":
		return logger.ERROR
	case "FATAL":
		return logger.FATAL
	default:
		return logger.INFO // default to INFO if invalid level provided
	}
}

func main() {
	var (
		err                  error
		wgconfig             WgConfig
		configFile           string
		remoteConfigURL      string
		reportBandwidthTo    string
		generateAndSaveKeyTo string
		reachableAt          string
		logLevel             string
		mtu                  string
	)

	interfaceName = os.Getenv("INTERFACE")
	configFile = os.Getenv("CONFIG")
	remoteConfigURL = os.Getenv("REMOTE_CONFIG")
	listenAddr = os.Getenv("LISTEN")
	reportBandwidthTo = os.Getenv("REPORT_BANDWIDTH_TO")
	generateAndSaveKeyTo = os.Getenv("GENERATE_AND_SAVE_KEY_TO")
	reachableAt = os.Getenv("REACHABLE_AT")
	logLevel = os.Getenv("LOG_LEVEL")
	mtu = os.Getenv("MTU")

	if interfaceName == "" {
		flag.StringVar(&interfaceName, "interface", "wg0", "Name of the WireGuard interface")
	}
	if configFile == "" {
		flag.StringVar(&configFile, "config", "", "Path to local configuration file")
	}
	if remoteConfigURL == "" {
		flag.StringVar(&remoteConfigURL, "remoteConfig", "", "URL to fetch remote configuration")
	}
	if listenAddr == "" {
		flag.StringVar(&listenAddr, "listen", ":3003", "Address to listen on")
	}
	if reportBandwidthTo == "" {
		flag.StringVar(&reportBandwidthTo, "reportBandwidthTo", "", "Address to listen on")
	}
	if generateAndSaveKeyTo == "" {
		flag.StringVar(&generateAndSaveKeyTo, "generateAndSaveKeyTo", "", "Path to save generated private key")
	}
	if reachableAt == "" {
		flag.StringVar(&reachableAt, "reachableAt", "", "Endpoint of the http server to tell remote config about")
	}
	if logLevel == "" {
		flag.StringVar(&logLevel, "log-level", "INFO", "Log level (DEBUG, INFO, WARN, ERROR, FATAL)")
	}
	if mtu == "" {
		flag.StringVar(&mtu, "mtu", "1280", "MTU of the WireGuard interface")
	}
	flag.Parse()

	logger.Init()
	logger.GetLogger().SetLevel(parseLogLevel(logLevel))

	mtuInt, err = strconv.Atoi(mtu)
	if err != nil {
		logger.Fatal("Failed to parse MTU: %v", err)
	}

	// are they missing either the config file or the remote config URL?
	if configFile == "" && remoteConfigURL == "" {
		logger.Fatal("You must provide either a config file or a remote config URL")
	}

	// do they have both the config file and the remote config URL?
	if configFile != "" && remoteConfigURL != "" {
		logger.Fatal("You must provide either a config file or a remote config URL, not both")
	}

	var key wgtypes.Key
	// if generateAndSaveKeyTo is provided, generate a private key and save it to the file. if the file already exists, load the key from the file
	if generateAndSaveKeyTo != "" {
		if _, err := os.Stat(generateAndSaveKeyTo); os.IsNotExist(err) {
			// generate a new private key
			key, err = wgtypes.GeneratePrivateKey()
			if err != nil {
				logger.Fatal("Failed to generate private key: %v", err)
			}
			// save the key to the file
			err = os.WriteFile(generateAndSaveKeyTo, []byte(key.String()), 0644)
			if err != nil {
				logger.Fatal("Failed to save private key: %v", err)
			}
		} else {
			keyData, err := os.ReadFile(generateAndSaveKeyTo)
			if err != nil {
				logger.Fatal("Failed to read private key: %v", err)
			}
			key, err = wgtypes.ParseKey(string(keyData))
			if err != nil {
				logger.Fatal("Failed to parse private key: %v", err)
			}
		}
	} else {
		// if no generateAndSaveKeyTo is provided, ensure that the private key is provided
		if wgconfig.PrivateKey == "" {
			// generate a new one
			key, err = wgtypes.GeneratePrivateKey()
			if err != nil {
				logger.Fatal("Failed to generate private key: %v", err)
			}
		}
	}

	// Load configuration based on provided argument
	if configFile != "" {
		wgconfig, err = loadConfig(configFile)
		if err != nil {
			logger.Fatal("Failed to load configuration: %v", err)
		}
		if wgconfig.PrivateKey == "" {
			wgconfig.PrivateKey = key.String()
		}
	} else {
		// loop until we get the config
		for wgconfig.PrivateKey == "" {
			logger.Info("Fetching remote config from %s", remoteConfigURL)
			wgconfig, err = loadRemoteConfig(remoteConfigURL, key, reachableAt)
			if err != nil {
				logger.Error("Failed to load configuration: %v", err)
				time.Sleep(5 * time.Second)
				continue
			}
			wgconfig.PrivateKey = key.String()
		}
	}

	wgClient, err = wgctrl.New()
	if err != nil {
		logger.Fatal("Failed to create WireGuard client: %v", err)
	}
	defer wgClient.Close()

	// Ensure the WireGuard interface exists and is configured
	if err := ensureWireguardInterface(wgconfig); err != nil {
		logger.Fatal("Failed to ensure WireGuard interface: %v", err)
	}

	// Ensure the WireGuard peers exist
	ensureWireguardPeers(wgconfig.Peers)

	if reportBandwidthTo != "" {
		go periodicBandwidthCheck(reportBandwidthTo)
	}

	http.HandleFunc("/peer", handlePeer)
	logger.Info("Starting server on %s", listenAddr)
	logger.Fatal("Failed to start server: %v", http.ListenAndServe(listenAddr, nil))
}

func loadRemoteConfig(url string, key wgtypes.Key, reachableAt string) (WgConfig, error) {
	var body *bytes.Buffer
	if reachableAt == "" {
		body = bytes.NewBuffer([]byte(fmt.Sprintf(`{"publicKey": "%s"}`, key.PublicKey().String())))
	} else {
		body = bytes.NewBuffer([]byte(fmt.Sprintf(`{"publicKey": "%s", "reachableAt": "%s"}`, key.PublicKey().String(), reachableAt)))
	}
	resp, err := http.Post(url, "application/json", body)
	if err != nil {
		// print the error
		logger.Error("Error fetching remote config %s: %v", url, err)
		return WgConfig{}, err
	}
	defer resp.Body.Close()

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return WgConfig{}, err
	}

	var config WgConfig
	err = json.Unmarshal(data, &config)

	return config, err
}

func loadConfig(filename string) (WgConfig, error) {
	// Open the JSON file
	file, err := os.Open(filename)
	if err != nil {
		logger.Error("Error opening file %s: %v", filename, err)
		return WgConfig{}, err
	}
	defer file.Close()

	// Read the file contents
	byteValue, err := io.ReadAll(file)
	if err != nil {
		logger.Error("Error reading file %s: %v", filename, err)
		return WgConfig{}, err
	}

	// Create a variable of the appropriate type to hold the unmarshaled data
	var wgconfig WgConfig

	// Unmarshal the JSON data into the struct
	err = json.Unmarshal(byteValue, &wgconfig)
	if err != nil {
		logger.Error("Error unmarshaling JSON data: %v", err)
		return WgConfig{}, err
	}

	return wgconfig, nil
}

func ensureWireguardInterface(wgconfig WgConfig) error {
	// Check if the WireGuard interface exists
	_, err := netlink.LinkByName(interfaceName)
	if err != nil {
		if _, ok := err.(netlink.LinkNotFoundError); ok {
			// Interface doesn't exist, so create it
			err = createWireGuardInterface()
			if err != nil {
				logger.Fatal("Failed to create WireGuard interface: %v", err)
			}
			logger.Info("Created WireGuard interface %s\n", interfaceName)
		} else {
			logger.Fatal("Error checking for WireGuard interface: %v", err)
		}
	} else {
		logger.Info("WireGuard interface %s already exists\n", interfaceName)
		return nil
	}

	// Assign IP address to the interface
	err = assignIPAddress(wgconfig.IpAddress)
	if err != nil {
		logger.Fatal("Failed to assign IP address: %v", err)
	}
	logger.Info("Assigned IP address %s to interface %s\n", wgconfig.IpAddress, interfaceName)

	// Check if the interface already exists
	_, err = wgClient.Device(interfaceName)
	if err != nil {
		return fmt.Errorf("interface %s does not exist", interfaceName)
	}

	// Parse the private key
	key, err := wgtypes.ParseKey(wgconfig.PrivateKey)
	if err != nil {
		return fmt.Errorf("failed to parse private key: %v", err)
	}

	// Create a new WireGuard configuration
	config := wgtypes.Config{
		PrivateKey: &key,
		ListenPort: new(int),
	}
	*config.ListenPort = wgconfig.ListenPort

	// Create and configure the WireGuard interface
	err = wgClient.ConfigureDevice(interfaceName, config)
	if err != nil {
		return fmt.Errorf("failed to configure WireGuard device: %v", err)
	}

	// bring up the interface
	link, err := netlink.LinkByName(interfaceName)
	if err != nil {
		return fmt.Errorf("failed to get interface: %v", err)
	}

	if err := netlink.LinkSetMTU(link, mtuInt); err != nil {
		return fmt.Errorf("failed to set MTU: %v", err)
	}

	if err := netlink.LinkSetUp(link); err != nil {
		return fmt.Errorf("failed to bring up interface: %v", err)
	}

	if err := ensureMSSClamping(); err != nil {
		logger.Warn("Failed to ensure MSS clamping: %v", err)
	}

	logger.Info("WireGuard interface %s created and configured", interfaceName)

	return nil
}

func createWireGuardInterface() error {
	wgLink := &netlink.GenericLink{
		LinkAttrs: netlink.LinkAttrs{Name: interfaceName},
		LinkType:  "wireguard",
	}
	return netlink.LinkAdd(wgLink)
}

func assignIPAddress(ipAddress string) error {
	link, err := netlink.LinkByName(interfaceName)
	if err != nil {
		return fmt.Errorf("failed to get interface: %v", err)
	}

	addr, err := netlink.ParseAddr(ipAddress)
	if err != nil {
		return fmt.Errorf("failed to parse IP address: %v", err)
	}

	return netlink.AddrAdd(link, addr)
}

func ensureWireguardPeers(peers []Peer) error {
	// get the current peers
	device, err := wgClient.Device(interfaceName)
	if err != nil {
		return fmt.Errorf("failed to get device: %v", err)
	}

	// get the peer public keys
	var currentPeers []string
	for _, peer := range device.Peers {
		currentPeers = append(currentPeers, peer.PublicKey.String())
	}

	// remove any peers that are not in the config
	for _, peer := range currentPeers {
		found := false
		for _, configPeer := range peers {
			if peer == configPeer.PublicKey {
				found = true
				break
			}
		}
		if !found {
			err := removePeer(peer)
			if err != nil {
				return fmt.Errorf("failed to remove peer: %v", err)
			}
		}
	}

	// add any peers that are in the config but not in the current peers
	for _, configPeer := range peers {
		found := false
		for _, peer := range currentPeers {
			if configPeer.PublicKey == peer {
				found = true
				break
			}
		}
		if !found {
			err := addPeer(configPeer)
			if err != nil {
				return fmt.Errorf("failed to add peer: %v", err)
			}
		}
	}

	return nil
}

func ensureMSSClamping() error {
	// Calculate MSS value (MTU - 40 for IPv4 header (20) and TCP header (20))
	mssValue := mtuInt - 40

	// Rules to be managed - just the chains, we'll construct the full command separately
	chains := []string{"INPUT", "OUTPUT", "FORWARD"}

	// First, try to delete any existing rules
	for _, chain := range chains {
		deleteCmd := exec.Command("/usr/sbin/iptables",
			"-t", "mangle",
			"-D", chain,
			"-p", "tcp",
			"--tcp-flags", "SYN,RST", "SYN",
			"-j", "TCPMSS",
			"--set-mss", fmt.Sprintf("%d", mssValue))

		logger.Info("Attempting to delete existing MSS clamping rule for chain %s", chain)

		// Try deletion multiple times to handle multiple existing rules
		for i := 0; i < 3; i++ {
			out, err := deleteCmd.CombinedOutput()
			if err != nil {
				// Convert exit status 1 to string for better logging
				if exitErr, ok := err.(*exec.ExitError); ok {
					logger.Debug("Deletion stopped for chain %s: %v (output: %s)",
						chain, exitErr.String(), string(out))
				}
				break // No more rules to delete
			}
			logger.Info("Deleted MSS clamping rule for chain %s (attempt %d)", chain, i+1)
		}
	}

	// Then add the new rules
	var errors []error
	for _, chain := range chains {
		addCmd := exec.Command("/usr/sbin/iptables",
			"-t", "mangle",
			"-A", chain,
			"-p", "tcp",
			"--tcp-flags", "SYN,RST", "SYN",
			"-j", "TCPMSS",
			"--set-mss", fmt.Sprintf("%d", mssValue))

		logger.Info("Adding MSS clamping rule for chain %s", chain)

		if out, err := addCmd.CombinedOutput(); err != nil {
			errMsg := fmt.Sprintf("Failed to add MSS clamping rule for chain %s: %v (output: %s)",
				chain, err, string(out))
			logger.Error(errMsg)
			errors = append(errors, fmt.Errorf(errMsg))
			continue
		}

		// Verify the rule was added
		checkCmd := exec.Command("/usr/sbin/iptables",
			"-t", "mangle",
			"-C", chain,
			"-p", "tcp",
			"--tcp-flags", "SYN,RST", "SYN",
			"-j", "TCPMSS",
			"--set-mss", fmt.Sprintf("%d", mssValue))

		if out, err := checkCmd.CombinedOutput(); err != nil {
			errMsg := fmt.Sprintf("Rule verification failed for chain %s: %v (output: %s)",
				chain, err, string(out))
			logger.Error(errMsg)
			errors = append(errors, fmt.Errorf(errMsg))
			continue
		}

		logger.Info("Successfully added and verified MSS clamping rule for chain %s", chain)
	}

	// If we encountered any errors, return them combined
	if len(errors) > 0 {
		var errMsgs []string
		for _, err := range errors {
			errMsgs = append(errMsgs, err.Error())
		}
		return fmt.Errorf("MSS clamping setup encountered errors:\n%s",
			strings.Join(errMsgs, "\n"))
	}

	return nil
}

func handlePeer(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodPost:
		handleAddPeer(w, r)
	case http.MethodDelete:
		handleRemovePeer(w, r)
	default:
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
	}
}

func handleAddPeer(w http.ResponseWriter, r *http.Request) {
	var peer Peer
	if err := json.NewDecoder(r.Body).Decode(&peer); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	err := addPeer(peer)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(map[string]string{"status": "Peer added successfully"})
}

func addPeer(peer Peer) error {
	pubKey, err := wgtypes.ParseKey(peer.PublicKey)
	if err != nil {
		return fmt.Errorf("failed to parse public key: %v", err)
	}

	// parse allowed IPs into array of net.IPNet
	var allowedIPs []net.IPNet
	for _, ipStr := range peer.AllowedIPs {
		_, ipNet, err := net.ParseCIDR(ipStr)
		if err != nil {
			return fmt.Errorf("failed to parse allowed IP: %v", err)
		}
		allowedIPs = append(allowedIPs, *ipNet)
	}

	peerConfig := wgtypes.PeerConfig{
		PublicKey:  pubKey,
		AllowedIPs: allowedIPs,
	}

	config := wgtypes.Config{
		Peers: []wgtypes.PeerConfig{peerConfig},
	}

	if err := wgClient.ConfigureDevice(interfaceName, config); err != nil {
		return fmt.Errorf("failed to add peer: %v", err)
	}

	logger.Info("Peer %s added successfully", peer.PublicKey)

	return nil
}

func handleRemovePeer(w http.ResponseWriter, r *http.Request) {
	publicKey := r.URL.Query().Get("public_key")
	if publicKey == "" {
		http.Error(w, "Missing public_key query parameter", http.StatusBadRequest)
		return
	}

	err := removePeer(publicKey)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(map[string]string{"status": "Peer removed successfully"})
}

func removePeer(publicKey string) error {
	pubKey, err := wgtypes.ParseKey(publicKey)
	if err != nil {
		return fmt.Errorf("failed to parse public key: %v", err)
	}

	peerConfig := wgtypes.PeerConfig{
		PublicKey: pubKey,
		Remove:    true,
	}

	config := wgtypes.Config{
		Peers: []wgtypes.PeerConfig{peerConfig},
	}

	if err := wgClient.ConfigureDevice(interfaceName, config); err != nil {
		return fmt.Errorf("failed to remove peer: %v", err)
	}

	logger.Info("Peer %s removed successfully", publicKey)

	return nil
}

func periodicBandwidthCheck(endpoint string) {
	ticker := time.NewTicker(10 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		if err := reportPeerBandwidth(endpoint); err != nil {
			logger.Info("Failed to report peer bandwidth: %v", err)
		}
	}
}

func calculatePeerBandwidth() ([]PeerBandwidth, error) {
	device, err := wgClient.Device(interfaceName)
	if err != nil {
		return nil, fmt.Errorf("failed to get device: %v", err)
	}

	peerBandwidths := []PeerBandwidth{}
	now := time.Now()

	mu.Lock()
	defer mu.Unlock()

	for _, peer := range device.Peers {
		publicKey := peer.PublicKey.String()
		currentReading := PeerReading{
			BytesReceived:    peer.ReceiveBytes,
			BytesTransmitted: peer.TransmitBytes,
			LastChecked:      now,
		}

		var bytesInDiff, bytesOutDiff float64
		lastReading, exists := lastReadings[publicKey]

		if exists {
			timeDiff := currentReading.LastChecked.Sub(lastReading.LastChecked).Seconds()
			if timeDiff > 0 {
				// Calculate bytes transferred since last reading
				bytesInDiff = float64(currentReading.BytesReceived - lastReading.BytesReceived)
				bytesOutDiff = float64(currentReading.BytesTransmitted - lastReading.BytesTransmitted)

				// Handle counter wraparound (if the counter resets or overflows)
				if bytesInDiff < 0 {
					bytesInDiff = float64(currentReading.BytesReceived)
				}
				if bytesOutDiff < 0 {
					bytesOutDiff = float64(currentReading.BytesTransmitted)
				}

				// Convert to MB
				bytesInMB := bytesInDiff / (1024 * 1024)
				bytesOutMB := bytesOutDiff / (1024 * 1024)

				peerBandwidths = append(peerBandwidths, PeerBandwidth{
					PublicKey: publicKey,
					BytesIn:   bytesInMB,
					BytesOut:  bytesOutMB,
				})
			} else {
				// If readings are too close together or time hasn't passed, report 0
				peerBandwidths = append(peerBandwidths, PeerBandwidth{
					PublicKey: publicKey,
					BytesIn:   0,
					BytesOut:  0,
				})
			}
		} else {
			// For first reading of a peer, report 0 to establish baseline
			peerBandwidths = append(peerBandwidths, PeerBandwidth{
				PublicKey: publicKey,
				BytesIn:   0,
				BytesOut:  0,
			})
		}

		// Update the last reading
		lastReadings[publicKey] = currentReading
	}

	// Clean up old peers
	for publicKey := range lastReadings {
		found := false
		for _, peer := range device.Peers {
			if peer.PublicKey.String() == publicKey {
				found = true
				break
			}
		}
		if !found {
			delete(lastReadings, publicKey)
		}
	}

	return peerBandwidths, nil
}

func reportPeerBandwidth(apiURL string) error {
	bandwidths, err := calculatePeerBandwidth()
	if err != nil {
		return fmt.Errorf("failed to calculate peer bandwidth: %v", err)
	}

	jsonData, err := json.Marshal(bandwidths)
	if err != nil {
		return fmt.Errorf("failed to marshal bandwidth data: %v", err)
	}

	resp, err := http.Post(apiURL, "application/json", bytes.NewBuffer(jsonData))
	if err != nil {
		return fmt.Errorf("failed to send bandwidth data: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("API returned non-OK status: %s", resp.Status)
	}

	return nil
}
