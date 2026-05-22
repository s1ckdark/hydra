package agent

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
)

// commandDenyPatterns are the regex patterns blocked from the LLM-proposed
// execute_command actions. These are guardrails against hallucinated
// destructive cleanup commands, not a sandbox — the user can still type
// any command directly into the chat. Anchored on word/path boundaries
// to avoid false positives like `gracefulShutdown` matching `shutdown`.
var commandDenyPatterns = []*regexp.Regexp{
	// rm -r / rm -rf rooted at /, ~, $HOME, or any first-level system dir.
	regexp.MustCompile(`(?i)\brm\s+-[a-zA-Z]*r[a-zA-Z]*\s+(/|~|\$HOME)`),
	// filesystem-level zap
	regexp.MustCompile(`(?i)\bmkfs\b`),
	regexp.MustCompile(`(?i)\bdd\s+if=`),
	// fork bomb
	regexp.MustCompile(`:\(\)\s*\{`),
	// host control — match only as the executable token, not substring
	regexp.MustCompile(`(?i)(^|[\s;&|])shutdown\b`),
	regexp.MustCompile(`(?i)(^|[\s;&|])reboot\b`),
	regexp.MustCompile(`(?i)(^|[\s;&|])halt\b`),
}

// Validator sanity-checks a plan against the current device cache before
// either Chat returns it or Execute runs it. Two phases catch:
//   - LLM hallucinating device IDs that don't exist
//   - Plans that were valid at Chat time but stale by Execute (device
//     removed from Tailscale in the gap)
type Validator struct {
	devices DeviceLister
	orchs   OrchLister
}

func NewValidator(d DeviceLister, o OrchLister) *Validator {
	return &Validator{devices: d, orchs: o}
}

// Validate returns one error per problem action; empty slice means the
// plan is runnable. The caller is responsible for surfacing the errors.
func (v *Validator) Validate(ctx context.Context, plan Plan) []error {
	deviceIDs := map[string]bool{}
	if v.devices != nil {
		devs, lerr := v.devices.ListDevices(ctx, false)
		if lerr != nil {
			return []error{fmt.Errorf("device cache unavailable: %w", lerr)}
		}
		for _, d := range devs {
			deviceIDs[d.ID] = true
		}
	}
	var errs []error
	for i, a := range plan.Actions {
		if err := v.validateOne(deviceIDs, i, a); err != nil {
			errs = append(errs, err)
		}
	}
	return errs
}

func (v *Validator) validateOne(devices map[string]bool, idx int, a Action) error {
	mustDevice := func(id string) error {
		if !devices[id] {
			return fmt.Errorf("action %d (%s): unknown device_id %q", idx, a.Type, id)
		}
		return nil
	}
	switch a.Type {
	case "get_metrics":
		var args getMetricsArgs
		if err := json.Unmarshal(a.Args, &args); err != nil {
			return fmt.Errorf("action %d (%s): args: %w", idx, a.Type, err)
		}
		return mustDevice(args.DeviceID)
	case "create_orch":
		var args createOrchArgs
		if err := json.Unmarshal(a.Args, &args); err != nil {
			return fmt.Errorf("action %d (%s): args: %w", idx, a.Type, err)
		}
		if err := mustDevice(args.HeadID); err != nil {
			return err
		}
		for _, w := range args.WorkerIDs {
			if err := mustDevice(w); err != nil {
				return err
			}
		}
		return nil
	case "execute_command":
		var args execCmdArgs
		if err := json.Unmarshal(a.Args, &args); err != nil {
			return fmt.Errorf("action %d (%s): args: %w", idx, a.Type, err)
		}
		if err := mustDevice(args.DeviceID); err != nil {
			return err
		}
		for _, p := range commandDenyPatterns {
			if p.MatchString(args.Command) {
				return fmt.Errorf("action %d (%s): command matches deny-list (%s)", idx, a.Type, p.String())
			}
		}
		return nil
	case "list_devices", "list_orchs", "get_gpu", "recent_tasks":
		return nil
	case "delete_orch":
		var args deleteOrchArgs
		if err := json.Unmarshal(a.Args, &args); err != nil {
			return fmt.Errorf("action %d (%s): args: %w", idx, a.Type, err)
		}
		if args.OrchID == "" {
			return errors.New("delete_orch: orch_id required")
		}
		return nil
	default:
		return fmt.Errorf("action %d: unknown type %q", idx, a.Type)
	}
}
