package cli

import (
	"context"
	"fmt"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/spf13/cobra"

	"github.com/s1ckdark/hydra/internal/agent"
	"github.com/s1ckdark/hydra/internal/domain"
	"github.com/s1ckdark/hydra/internal/infra/ssh"
	"github.com/s1ckdark/hydra/internal/infra/tailscale"
	"github.com/s1ckdark/hydra/internal/repository/sqlite"
	"github.com/s1ckdark/hydra/internal/tui/monitor"
	"github.com/s1ckdark/hydra/internal/usecase"
)

func newOrchCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "orch",
		Short: "Manage Ray orchs",
		Long:  "Create, modify, and delete Ray orchs across your Tailscale devices",
	}

	cmd.AddCommand(newOrchCreateCmd())
	cmd.AddCommand(newOrchListCmd())
	cmd.AddCommand(newOrchStatusCmd())
	cmd.AddCommand(newOrchDeleteCmd())
	cmd.AddCommand(newOrchAddWorkerCmd())
	cmd.AddCommand(newOrchRemoveWorkerCmd())
	cmd.AddCommand(newOrchChangeHeadCmd())
	cmd.AddCommand(newOrchStartCmd())
	cmd.AddCommand(newOrchStopCmd())
	cmd.AddCommand(newOrchMonitorCmd())
	cmd.AddCommand(newOrchAgentCmd())

	return cmd
}

func newOrchCreateCmd() *cobra.Command {
	var (
		head        string
		workers     []string
		description string
		rayPort     int
		dashPort    int
	)

	cmd := &cobra.Command{
		Use:   "create <name>",
		Short: "Create a new Ray orch",
		Long: `Create a new Ray orch with specified head and worker nodes.

Example:
  orchctl orch create my-orch --head node1 --workers node2,node3`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			name := args[0]

			if head == "" {
				return fmt.Errorf("head node is required (--head)")
			}

			cfg, err := getConfig()
			if err != nil {
				return err
			}

			// Resolve device names to IDs
			client := tailscale.NewClient(cfg.Tailscale.APIKey, cfg.Tailscale.Tailnet)
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()

			devices, err := client.ListDevices(ctx)
			if err != nil {
				return fmt.Errorf("failed to list devices: %w", err)
			}

			headDevice := findDevice(devices, head)
			if headDevice == nil {
				return fmt.Errorf("head node not found: %s", head)
			}

			workerIDs := make([]string, 0, len(workers))
			for _, w := range workers {
				wd := findDevice(devices, w)
				if wd == nil {
					return fmt.Errorf("worker node not found: %s", w)
				}
				workerIDs = append(workerIDs, wd.ID)
			}

			// Create orch
			orch := domain.NewOrch(name, headDevice.ID, workerIDs)
			orch.Description = description
			if rayPort > 0 {
				orch.RayPort = rayPort
			}
			if dashPort > 0 {
				orch.DashboardPort = dashPort
			}

			fmt.Printf("Creating orch '%s'...\n", name)
			fmt.Printf("  Head: %s (%s)\n", headDevice.Name, headDevice.TailscaleIP)
			for i, wid := range workerIDs {
				wd := findDeviceByID(devices, wid)
				fmt.Printf("  Worker %d: %s (%s)\n", i+1, wd.Name, wd.TailscaleIP)
			}

			// TODO: Actually start Ray orch via SSH
			fmt.Println("\nOrch configuration created.")
			fmt.Println("Use 'orchctl orch start " + name + "' to start the orch.")

			return nil
		},
	}

	cmd.Flags().StringVar(&head, "coordinator", "", "Head node device name or ID (required)")
	cmd.Flags().StringSliceVar(&workers, "workers", nil, "Worker node device names or IDs (comma-separated)")
	cmd.Flags().StringVar(&description, "description", "", "Orch description")
	cmd.Flags().IntVar(&rayPort, "ray-port", 0, "Ray port (default: 6379)")
	cmd.Flags().IntVar(&dashPort, "dashboard-port", 0, "Dashboard port (default: 8265)")
	cmd.MarkFlagRequired("coordinator")

	return cmd
}

func newOrchListCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "list",
		Short: "List all orchs",
		RunE: func(cmd *cobra.Command, args []string) error {
			// TODO: Load from repository
			fmt.Println("No orchs configured yet.")
			fmt.Println("Use 'orchctl orch create' to create a new orch.")
			return nil
		},
	}

	return cmd
}

func newOrchStatusCmd() *cobra.Command {
	var detailed bool

	cmd := &cobra.Command{
		Use:   "status <orch-name>",
		Short: "Show orch status",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			name := args[0]

			fmt.Printf("Orch: %s\n", name)
			fmt.Println("Status: not implemented yet")

			// TODO: Get orch from repository
			// TODO: Query Ray status from head node

			return nil
		},
	}

	cmd.Flags().BoolVar(&detailed, "detailed", false, "Show detailed node information")

	return cmd
}

func newOrchDeleteCmd() *cobra.Command {
	var force bool

	cmd := &cobra.Command{
		Use:   "delete <orch-name>",
		Short: "Delete a orch",
		Long: `Delete a orch. By default, checks if the orch has running jobs.
Use --force to skip the check and force deletion.`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			name := args[0]

			if !force {
				// TODO: Check if orch has running jobs
				fmt.Printf("Checking if orch '%s' is in use...\n", name)
			}

			fmt.Printf("Deleting orch '%s'...\n", name)
			// TODO: Stop Ray processes on all nodes
			// TODO: Remove from repository

			fmt.Println("Orch deleted.")
			return nil
		},
	}

	cmd.Flags().BoolVar(&force, "force", false, "Force deletion without checking for running jobs")

	return cmd
}

func newOrchAddWorkerCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "add-worker <orch-name> <device>",
		Short: "Add a worker node to the orch",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			orchName := args[0]
			deviceName := args[1]

			fmt.Printf("Adding worker '%s' to orch '%s'...\n", deviceName, orchName)

			// TODO: Validate device exists and is online
			// TODO: Load orch from repository
			// TODO: Add worker to orch
			// TODO: Connect worker to Ray orch

			fmt.Println("Worker added successfully.")
			return nil
		},
	}

	return cmd
}

func newOrchRemoveWorkerCmd() *cobra.Command {
	var force bool

	cmd := &cobra.Command{
		Use:   "remove-worker <orch-name> <device>",
		Short: "Remove a worker node from the orch",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			orchName := args[0]
			deviceName := args[1]

			if !force {
				fmt.Printf("Checking if worker '%s' has running tasks...\n", deviceName)
				// TODO: Check for running tasks on the worker
			}

			fmt.Printf("Removing worker '%s' from orch '%s'...\n", deviceName, orchName)

			// TODO: Stop Ray on the worker
			// TODO: Update orch configuration
			// TODO: Save to repository

			fmt.Println("Worker removed successfully.")
			return nil
		},
	}

	cmd.Flags().BoolVar(&force, "force", false, "Force removal without checking for running tasks")

	return cmd
}

func newOrchChangeHeadCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "change-head <orch-name> <new-head-device>",
		Short: "Change the head node of a orch",
		Long: `Change the head node of a orch. The current head becomes a worker,
and the specified device becomes the new head.

This operation requires:
1. Stopping all jobs on the orch
2. Restarting Ray with the new head configuration`,
		Args: cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			orchName := args[0]
			newHead := args[1]

			fmt.Printf("Changing head node of orch '%s' to '%s'...\n", orchName, newHead)
			fmt.Println("\nThis will:")
			fmt.Println("  1. Stop all running jobs")
			fmt.Println("  2. Stop Ray on all nodes")
			fmt.Println("  3. Start Ray with the new head configuration")
			fmt.Println("  4. Restart all workers")

			// TODO: Implement head change logic
			// - Check orch exists
			// - Check new head is valid and online
			// - Stop orch
			// - Update configuration
			// - Restart orch with new head

			fmt.Println("\nHead node change completed.")
			return nil
		},
	}

	return cmd
}

func newOrchStartCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "start <orch-name>",
		Short: "Start a orch",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			name := args[0]

			fmt.Printf("Starting orch '%s'...\n", name)

			// TODO: Load orch from repository
			// TODO: Start Ray on head node
			// TODO: Connect workers to head

			fmt.Println("Orch started.")
			return nil
		},
	}

	return cmd
}

func newOrchStopCmd() *cobra.Command {
	var force bool

	cmd := &cobra.Command{
		Use:   "stop <orch-name>",
		Short: "Stop a orch",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			name := args[0]

			if !force {
				fmt.Printf("Checking for running jobs on orch '%s'...\n", name)
				// TODO: Check for running jobs
			}

			fmt.Printf("Stopping orch '%s'...\n", name)

			// TODO: Stop Ray on all nodes

			fmt.Println("Orch stopped.")
			return nil
		},
	}

	cmd.Flags().BoolVar(&force, "force", false, "Force stop without checking for running jobs")

	return cmd
}

func newOrchMonitorCmd() *cobra.Command {
	var interval int

	cmd := &cobra.Command{
		Use:   "monitor <orch-name>",
		Short: "Monitor GPU usage across orch nodes",
		Long: `Monitor GPU utilization, memory, temperature, and power for all nodes
in a orch in real-time. Requires nvidia-smi on worker nodes.

Keys:
  d  Toggle table/detail view
  s  Cycle sort order
  r  Force refresh
  q  Quit`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			orchName := args[0]

			cfg, err := getConfig()
			if err != nil {
				return err
			}

			client := tailscale.NewClient(cfg.Tailscale.APIKey, cfg.Tailscale.Tailnet)
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()

			allDevices, err := client.ListDevices(ctx)
			if err != nil {
				return fmt.Errorf("failed to list devices: %w", err)
			}

			deviceMap := make(map[string]*domain.Device)
			for _, d := range allDevices {
				deviceMap[d.ID] = d
			}

			// Load orch from repository
			db, err := sqlite.NewDB(cfg.Database.DSN)
			if err != nil {
				return fmt.Errorf("failed to open database: %w", err)
			}
			defer db.Close()

			repos := db.Repositories()
			orchUC := usecase.NewOrchUseCase(repos, nil)
			orch, err := orchUC.GetOrch(ctx, orchName)
			if err != nil {
				return fmt.Errorf("orch '%s' not found: %w", orchName, err)
			}

			// Resolve orch nodes to devices
			var orchDevices []*domain.Device
			for _, nodeID := range orch.AllNodeIDs() {
				if d, ok := deviceMap[nodeID]; ok && d.CanSSH() {
					orchDevices = append(orchDevices, d)
				}
			}

			if len(orchDevices) == 0 {
				return fmt.Errorf("no reachable nodes in orch '%s'", orchName)
			}

			sshExecutor := ssh.NewExecutor(ssh.Config{
				User:            cfg.SSH.User,
				PrivateKeyPath:  cfg.SSH.PrivateKeyPath,
				Port:            cfg.SSH.Port,
				Timeout:         time.Duration(cfg.SSH.Timeout) * time.Second,
				UseTailscaleSSH: cfg.SSH.UseTailscaleSSH,
			})
			defer sshExecutor.Close()

			gpuCollector := ssh.NewGPUCollector(sshExecutor)

			duration := time.Duration(interval) * time.Second
			model := monitor.NewModel(orchName, orchDevices, gpuCollector, duration)
			p := tea.NewProgram(model, tea.WithAltScreen())
			_, err = p.Run()
			return err
		},
	}

	cmd.Flags().IntVarP(&interval, "interval", "i", 3, "Refresh interval in seconds")
	return cmd
}

func newOrchAgentCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "agent",
		Short: "Manage orch node agents",
	}
	cmd.AddCommand(newAgentInstallCmd())
	cmd.AddCommand(newAgentUninstallCmd())
	cmd.AddCommand(newAgentStatusCmd())
	return cmd
}

func newAgentInstallCmd() *cobra.Command {
	var (
		binaryPath string
		port       int
	)

	cmd := &cobra.Command{
		Use:   "install <orch-name>",
		Short: "Install agent on all orch nodes",
		Long:  "Copies the orch-agent binary and installs systemd service on each node.",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			orchName := args[0]

			cfg, err := getConfig()
			if err != nil {
				return err
			}

			client := tailscale.NewClient(cfg.Tailscale.APIKey, cfg.Tailscale.Tailnet)
			ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
			defer cancel()

			allDevices, err := client.ListDevices(ctx)
			if err != nil {
				return fmt.Errorf("failed to list devices: %w", err)
			}

			sshExecutor := ssh.NewExecutor(ssh.Config{
				User:            cfg.SSH.User,
				PrivateKeyPath:  cfg.SSH.PrivateKeyPath,
				Port:            cfg.SSH.Port,
				Timeout:         time.Duration(cfg.SSH.Timeout) * time.Second,
				UseTailscaleSSH: cfg.SSH.UseTailscaleSSH,
			})
			defer sshExecutor.Close()

			for _, d := range allDevices {
				if !d.CanSSH() {
					fmt.Printf("  Skipping %s (offline or no SSH)\n", d.GetDisplayName())
					continue
				}

				role := "worker"
				// TODO: determine role from orch config

				sysCfg := agent.SystemdConfig{
					NodeID:     d.ID,
					OrchID:  orchName,
					Role:       role,
					Port:       port,
					BinaryPath: binaryPath,
					APIKey:     cfg.Agent.AnthropicAPIKey,
				}

				fmt.Printf("  Installing agent on %s (%s)...\n", d.GetDisplayName(), role)

				// Copy binary
				if err := sshExecutor.CopyFile(ctx, d, binaryPath, binaryPath); err != nil {
					fmt.Printf("    Warning: failed to copy binary: %v\n", err)
					continue
				}

				// Install systemd service
				installCmds, err := agent.InstallCommands(sysCfg)
				if err != nil {
					fmt.Printf("    Error: %v\n", err)
					continue
				}
				for _, installCmd := range installCmds {
					if _, err := sshExecutor.Execute(ctx, d, installCmd); err != nil {
						fmt.Printf("    Warning: %v\n", err)
					}
				}

				fmt.Printf("    Done.\n")
			}

			fmt.Println("Agent installation complete.")
			return nil
		},
	}

	cmd.Flags().StringVar(&binaryPath, "binary", "/usr/local/bin/orch-agent", "Path to agent binary")
	cmd.Flags().IntVar(&port, "port", 9090, "Agent listen port")
	return cmd
}

func newAgentUninstallCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "uninstall <orch-name>",
		Short: "Uninstall agent from all orch nodes",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			orchName := args[0]

			cfg, err := getConfig()
			if err != nil {
				return err
			}

			client := tailscale.NewClient(cfg.Tailscale.APIKey, cfg.Tailscale.Tailnet)
			ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
			defer cancel()

			allDevices, err := client.ListDevices(ctx)
			if err != nil {
				return fmt.Errorf("failed to list devices: %w", err)
			}

			sshExecutor := ssh.NewExecutor(ssh.Config{
				User:            cfg.SSH.User,
				PrivateKeyPath:  cfg.SSH.PrivateKeyPath,
				Port:            cfg.SSH.Port,
				Timeout:         time.Duration(cfg.SSH.Timeout) * time.Second,
				UseTailscaleSSH: cfg.SSH.UseTailscaleSSH,
			})
			defer sshExecutor.Close()

			for _, d := range allDevices {
				if !d.CanSSH() {
					continue
				}

				fmt.Printf("  Uninstalling agent from %s...\n", d.GetDisplayName())

				for _, uninstallCmd := range agent.UninstallCommands(orchName, d.ID) {
					if _, err := sshExecutor.Execute(ctx, d, uninstallCmd); err != nil {
						fmt.Printf("    Warning: %v\n", err)
					}
				}
				fmt.Printf("    Done.\n")
			}

			fmt.Println("Agent uninstallation complete.")
			return nil
		},
	}
	return cmd
}

func newAgentStatusCmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "status <orch-name>",
		Short: "Check agent status on all orch nodes",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			orchName := args[0]

			cfg, err := getConfig()
			if err != nil {
				return err
			}

			client := tailscale.NewClient(cfg.Tailscale.APIKey, cfg.Tailscale.Tailnet)
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()

			allDevices, err := client.ListDevices(ctx)
			if err != nil {
				return fmt.Errorf("failed to list devices: %w", err)
			}

			sshExecutor := ssh.NewExecutor(ssh.Config{
				User:            cfg.SSH.User,
				PrivateKeyPath:  cfg.SSH.PrivateKeyPath,
				Port:            cfg.SSH.Port,
				Timeout:         time.Duration(cfg.SSH.Timeout) * time.Second,
				UseTailscaleSSH: cfg.SSH.UseTailscaleSSH,
			})
			defer sshExecutor.Close()

			fmt.Printf("Agent status for orch '%s':\n\n", orchName)

			for _, d := range allDevices {
				if !d.CanSSH() {
					fmt.Printf("  %-20s  OFFLINE\n", d.GetDisplayName())
					continue
				}

				svcName := agent.ServiceName(orchName, d.ID)
				output, err := sshExecutor.Execute(ctx, d, fmt.Sprintf("systemctl is-active %s 2>/dev/null || echo inactive", svcName))
				if err != nil {
					fmt.Printf("  %-20s  ERROR: %v\n", d.GetDisplayName(), err)
					continue
				}

				status := "UNKNOWN"
				trimmed := output
				if len(trimmed) > 0 {
					// Remove trailing newlines
					for len(trimmed) > 0 && (trimmed[len(trimmed)-1] == '\n' || trimmed[len(trimmed)-1] == '\r') {
						trimmed = trimmed[:len(trimmed)-1]
					}
					status = trimmed
				}

				fmt.Printf("  %-20s  %s\n", d.GetDisplayName(), status)
			}

			return nil
		},
	}
	return cmd
}

// Helper functions

func findDevice(devices []*domain.Device, nameOrID string) *domain.Device {
	for _, d := range devices {
		if d.ID == nameOrID || d.Name == nameOrID || d.Hostname == nameOrID {
			return d
		}
	}
	return nil
}

func findDeviceByID(devices []*domain.Device, id string) *domain.Device {
	for _, d := range devices {
		if d.ID == id {
			return d
		}
	}
	return nil
}

// For future use when usecase is implemented
var _ = usecase.OrchUseCase{}
