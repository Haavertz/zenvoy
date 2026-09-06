package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"zenvoy/internal/email"
	"zenvoy/internal/himalaya"
)

const himalayaTimeout = 30 * time.Second

type emailLister interface {
	ListMailboxes(ctx context.Context) (email.ListResponse, error)
	ListEnvelopes(ctx context.Context) (email.EnvelopeListResponse, error)
}

func run(ctx context.Context, client emailLister, stdout io.Writer) error {
	var mailboxes email.ListResponse
	var envelopes email.EnvelopeListResponse
	var mailboxErr error
	var envelopeErr error

	var waitGroup sync.WaitGroup
	waitGroup.Add(2)

	go func() {
		defer waitGroup.Done()
		mailboxes, mailboxErr = client.ListMailboxes(ctx)
	}()

	go func() {
		defer waitGroup.Done()
		envelopes, envelopeErr = client.ListEnvelopes(ctx)
	}()

	waitGroup.Wait()

	if mailboxErr != nil {
		return mailboxErr
	}

	if envelopeErr != nil {
		return envelopeErr
	}

	response := email.InitialResponse{
		Mailboxes: mailboxes.Mailboxes,
		Envelopes: envelopes.Envelopes,
	}

	if err := json.NewEncoder(stdout).Encode(response); err != nil {
		return fmt.Errorf("encode initial email JSON: %w", err)
	}

	return nil
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), himalayaTimeout)
	defer cancel()

	if err := run(ctx, himalaya.NewClient(), os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
