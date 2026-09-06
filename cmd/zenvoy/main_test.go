package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"testing"

	"zenvoy/internal/email"
)

type fakeMailboxLister struct {
	response email.ListResponse
	err      error
}

func (lister fakeMailboxLister) ListMailboxes(context.Context) (email.ListResponse, error) {
	return lister.response, lister.err
}

func TestRunPrintsMailboxJSON(t *testing.T) {
	total := 42
	unread := 7
	lister := fakeMailboxLister{
		response: email.ListResponse{
			Mailboxes: []email.Folder{
				{
					ID:     "Inbox",
					Name:   "Inbox",
					Total:  &total,
					Unread: &unread,
				},
			},
		},
	}
	var stdout bytes.Buffer

	if err := run(context.Background(), lister, &stdout); err != nil {
		t.Fatalf("run() error = %v", err)
	}

	var output email.ListResponse
	if err := json.Unmarshal(stdout.Bytes(), &output); err != nil {
		t.Fatalf("stdout is not valid JSON: %v", err)
	}

	if len(output.Mailboxes) != 1 || output.Mailboxes[0].ID != "Inbox" {
		t.Fatalf("stdout mailbox response = %#v", output)
	}
}

func TestRunReturnsMailboxError(t *testing.T) {
	wantErr := errors.New("mailbox failure")
	lister := fakeMailboxLister{err: wantErr}

	err := run(context.Background(), lister, &bytes.Buffer{})
	if !errors.Is(err, wantErr) {
		t.Fatalf("run() error = %v, want wrapped %v", err, wantErr)
	}
}
