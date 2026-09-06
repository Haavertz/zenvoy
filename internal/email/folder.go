package email

type ListResponse struct {
	Mailboxes []Folder `json:"mailboxes"`
}

type Folder struct {
	ID     string `json:"id"`
	Name   string `json:"name"`
	Total  *int   `json:"total"`
	Unread *int   `json:"unread"`
}
