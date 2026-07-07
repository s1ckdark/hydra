package domain

import "testing"

// --- D2: status whitelist validation ---
//
// IsValidTaskStatus guards APITaskUpdateStatus against arbitrary status
// strings (e.g. {"status":"bogus"}) being written into a task's Status
// field. Only the seven domain.TaskStatus constants are valid.

func TestIsValidTaskStatus_KnownStatusesAccepted(t *testing.T) {
	valid := []TaskStatus{
		TaskStatusPending,
		TaskStatusQueued,
		TaskStatusAssigned,
		TaskStatusRunning,
		TaskStatusCompleted,
		TaskStatusFailed,
		TaskStatusCancelled,
	}
	for _, s := range valid {
		if !IsValidTaskStatus(s) {
			t.Errorf("IsValidTaskStatus(%q) = false, want true", s)
		}
	}
}

func TestIsValidTaskStatus_UnknownStatusRejected(t *testing.T) {
	for _, s := range []TaskStatus{"bogus", "", "Completed", "RUNNING"} {
		if IsValidTaskStatus(s) {
			t.Errorf("IsValidTaskStatus(%q) = true, want false", s)
		}
	}
}
