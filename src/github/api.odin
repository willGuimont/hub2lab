#+vet
package github

import "../utils"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Repo :: struct {
	name:        string,
	full_name:   string,
	ssh_url:     string,
	private:     bool,
	description: string,
}

RepoJSON :: struct {
	name:        string,
	full_name:   string,
	ssh_url:     string,
	private:     bool,
	description: string,
}

fetch_all_repos :: proc(token: string) -> [dynamic]Repo {
	repos := make([dynamic]Repo)

	page := 1
	per_page := 100

	for {
		url := fmt.tprintf(
			"https://api.github.com/user/repos?per_page=%d&page=%d&type=all",
			per_page,
			page,
		)

		headers := make(map[string]string)
		defer delete(headers)
		headers["Authorization"] = fmt.tprintf("Bearer %s", token)
		headers["Accept"] = "application/vnd.github.v3+json"

		resp, ok := utils.get(url, headers)
		if !ok || resp.status_code != 200 {
			fmt.printf(
				"Failed to fetch GitHub repos (Page %d): Status %d\n",
				page,
				resp.status_code,
			)
			fmt.println(resp.body)
			break
		}

		data := transmute([]byte)resp.body

		batch: [dynamic]RepoJSON
		err := json.unmarshal(data, &batch)
		if err != nil {
			fmt.println("JSON Parse Error:", err)
			break
		}
		defer delete(batch)

		if len(batch) == 0 {
			break
		}

		for r in batch {
			append(
				&repos,
				Repo {
					name = r.name,
					full_name = r.full_name,
					ssh_url = r.ssh_url,
					private = r.private,
					description = r.description,
				},
			)
		}

		if len(batch) < per_page {
			break
		}

		page += 1
		delete(resp.body)
	}

	return repos
}

User :: struct {
	login: string,
}

get_user :: proc(token: string) -> (string, bool) {
	url := "https://api.github.com/user"
	headers := make(map[string]string)
	defer delete(headers)
	headers["Authorization"] = fmt.tprintf("Bearer %s", token)
	headers["Accept"] = "application/vnd.github.v3+json"

	resp, ok := utils.get(url, headers)

	if !ok || resp.status_code != 200 {
		return "", false
	}
	defer delete(resp.body)

	data := transmute([]byte)resp.body
	user: User
	err := json.unmarshal(data, &user)
	if err != nil {
		return "", false
	}

	return strings.clone(user.login), true
}
