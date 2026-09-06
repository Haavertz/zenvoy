package himalaya

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
)

type fakeRunner struct {
	output []byte
	err    error
	args   []string
}

func (runner *fakeRunner) Run(_ context.Context, args ...string) ([]byte, error) {
	runner.args = append([]string(nil), args...)
	return runner.output, runner.err
}

func TestListMailboxesRunsHimalayaAndDecodesJSON(t *testing.T) {
	runner := &fakeRunner{
		output: []byte(`{"mailboxes":[{"id":"Inbox","name":"Inbox","total":42,"unread":7}]}`),
	}
	client := Client{runner: runner}

	response, err := client.ListMailboxes(context.Background())
	if err != nil {
		t.Fatalf("ListMailboxes() error = %v", err)
	}

	wantArgs := []string{"mailbox", "list", "--json", "--log-level", "off"}
	if !reflect.DeepEqual(runner.args, wantArgs) {
		t.Fatalf("Himalaya arguments = %v, want %v", runner.args, wantArgs)
	}

	if len(response.Mailboxes) != 1 {
		t.Fatalf("mailbox count = %d, want 1", len(response.Mailboxes))
	}

	mailbox := response.Mailboxes[0]
	if mailbox.ID != "Inbox" || mailbox.Name != "Inbox" {
		t.Fatalf("mailbox identity = %#v", mailbox)
	}

	if mailbox.Total == nil || *mailbox.Total != 42 {
		t.Fatalf("mailbox total = %v, want 42", mailbox.Total)
	}

	if mailbox.Unread == nil || *mailbox.Unread != 7 {
		t.Fatalf("mailbox unread = %v, want 7", mailbox.Unread)
	}
}

func TestListMailboxesReturnsRunnerError(t *testing.T) {
	runnerErr := errors.New("himalaya failed")
	client := Client{runner: &fakeRunner{err: runnerErr}}

	_, err := client.ListMailboxes(context.Background())
	if !errors.Is(err, runnerErr) {
		t.Fatalf("ListMailboxes() error = %v, want wrapped %v", err, runnerErr)
	}
}

func TestListMailboxesRejectsInvalidJSON(t *testing.T) {
	client := Client{runner: &fakeRunner{output: []byte("not-json")}}

	_, err := client.ListMailboxes(context.Background())
	if err == nil || !strings.Contains(err.Error(), "decode Himalaya mailbox JSON") {
		t.Fatalf("ListMailboxes() error = %v, want JSON decoding error", err)
	}
}
