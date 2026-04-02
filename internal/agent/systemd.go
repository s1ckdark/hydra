package agent

import (
	"fmt"
	"regexp"
	"strings"
)

var identifierPattern = regexp.MustCompile(`^[a-zA-Z0-9._-]+$`)
var pathPattern = regexp.MustCompile(`^[a-zA-Z0-9._/+-]+$`)

// ValidateIdentifier checks that a string contains only safe characters for use in
// shell commands and file paths.
func ValidateIdentifier(s string) error {
	if s == "" {
		return fmt.Errorf("identifier must not be empty")
	}
	if !identifierPattern.MatchString(s) {
		return fmt.Errorf("identifier %q contains invalid characters (allowed: a-zA-Z0-9._-)", s)
	}
	return nil
}

// ValidatePath checks that a path contains only safe characters.
func ValidatePath(s string) error {
	if s == "" {
		return fmt.Errorf("path must not be empty")
	}
	if !pathPattern.MatchString(s) {
		return fmt.Errorf("path %q contains invalid characters (allowed: a-zA-Z0-9._/+-)", s)
	}
	return nil
}

// SystemdConfig holds configuration for generating a systemd unit file.
type SystemdConfig struct {
	NodeID     string
	OrchID  string
	Role       string
	Port       int
	BinaryPath string
	APIKey     string
}

// GenerateSystemdUnit returns the content of a systemd unit file for the agent.
func GenerateSystemdUnit(cfg SystemdConfig) (string, error) {
	for _, pair := range []struct{ name, value string }{
		{"NodeID", cfg.NodeID},
		{"OrchID", cfg.OrchID},
		{"Role", cfg.Role},
	} {
		if err := ValidateIdentifier(pair.value); err != nil {
			return "", fmt.Errorf("invalid %s: %w", pair.name, err)
		}
	}
	if err := ValidatePath(cfg.BinaryPath); err != nil {
		return "", fmt.Errorf("invalid BinaryPath: %w", err)
	}

	svcName := ServiceName(cfg.OrchID, cfg.NodeID)

	lines := []string{
		"[Unit]",
		fmt.Sprintf("Description=Orch Agent for %s node %s", cfg.OrchID, cfg.NodeID),
		"After=network-online.target",
		"Wants=network-online.target",
		"",
		"[Service]",
		"Type=simple",
		fmt.Sprintf("ExecStart=%s --node-id %s --orch-id %s --role %s --port %d",
			cfg.BinaryPath, cfg.NodeID, cfg.OrchID, cfg.Role, cfg.Port),
		"Restart=always",
		"RestartSec=5",
	}

	if cfg.APIKey != "" {
		lines = append(lines, fmt.Sprintf("EnvironmentFile=/etc/orch-agent/%s.env", svcName))
	}

	lines = append(lines,
		"StandardOutput=journal",
		"StandardError=journal",
		fmt.Sprintf("SyslogIdentifier=%s", svcName),
		"",
		"[Install]",
		"WantedBy=multi-user.target",
		"",
	)

	return strings.Join(lines, "\n"), nil
}

// GenerateEnvFile generates the content of the environment file for the systemd service.
func GenerateEnvFile(cfg SystemdConfig) string {
	return fmt.Sprintf("ANTHROPIC_API_KEY=%s\n", cfg.APIKey)
}

// ServiceName returns the systemd service name for a given orch and node.
func ServiceName(orchID, nodeID string) string {
	return fmt.Sprintf("orch-agent-%s-%s", orchID, nodeID)
}

// ValidatedServiceName returns the systemd service name after validating inputs.
func ValidatedServiceName(orchID, nodeID string) (string, error) {
	if err := ValidateIdentifier(orchID); err != nil {
		return "", fmt.Errorf("invalid OrchID: %w", err)
	}
	if err := ValidateIdentifier(nodeID); err != nil {
		return "", fmt.Errorf("invalid NodeID: %w", err)
	}
	return ServiceName(orchID, nodeID), nil
}

// UnitFilePath returns the path to the systemd unit file.
func UnitFilePath(orchID, nodeID string) string {
	return fmt.Sprintf("/etc/systemd/system/%s.service", ServiceName(orchID, nodeID))
}

// InstallCommands returns the shell commands to install and start the systemd service.
func InstallCommands(cfg SystemdConfig) ([]string, error) {
	for _, pair := range []struct{ name, value string }{
		{"NodeID", cfg.NodeID},
		{"OrchID", cfg.OrchID},
		{"Role", cfg.Role},
	} {
		if err := ValidateIdentifier(pair.value); err != nil {
			return nil, fmt.Errorf("invalid %s: %w", pair.name, err)
		}
	}
	if err := ValidatePath(cfg.BinaryPath); err != nil {
		return nil, fmt.Errorf("invalid BinaryPath: %w", err)
	}

	name := ServiceName(cfg.OrchID, cfg.NodeID)
	unitPath := UnitFilePath(cfg.OrchID, cfg.NodeID)

	var cmds []string

	// Create env file directory and write env file before the unit file
	if cfg.APIKey != "" {
		cmds = append(cmds,
			"mkdir -p /etc/orch-agent",
			fmt.Sprintf("install -m 0600 /dev/stdin /etc/orch-agent/%s.env", name),
		)
	}

	cmds = append(cmds,
		fmt.Sprintf("tee %s", unitPath),
		"systemctl daemon-reload",
		fmt.Sprintf("systemctl enable %s", name),
		fmt.Sprintf("systemctl start %s", name),
	)
	return cmds, nil
}

// UninstallCommands returns the shell commands to stop, disable, and remove the systemd service.
func UninstallCommands(orchID, nodeID string) []string {
	name := ServiceName(orchID, nodeID)
	unitPath := UnitFilePath(orchID, nodeID)
	return []string{
		fmt.Sprintf("systemctl stop %s", name),
		fmt.Sprintf("systemctl disable %s", name),
		fmt.Sprintf("rm %s", unitPath),
		"systemctl daemon-reload",
	}
}
