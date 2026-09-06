package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"time"

	"zenvoy/internal/email"
	"zenvoy/internal/himalaya"
)

const himalayaTimeout = 30 * time.Second

type mailboxLister interface {
	ListMailboxes(ctx context.Context) (email.ListResponse, error)
}

func run(ctx context.Context, client mailboxLister, stdout io.Writer) error {
	mailboxes, err := client.ListMailboxes(ctx)
	if err != nil {
		return err
	}

	if err := json.NewEncoder(stdout).Encode(mailboxes); err != nil {
		return fmt.Errorf("encode mailbox JSON: %w", err)
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
