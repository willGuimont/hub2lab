#+vet
package gitlab

import "../utils"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Repo :: struct {
	id:                  int,
	path_with_namespace: string,
	ssh_url_to_repo:     string,
	visibility:          string,
	description:         string,
}

RepoJSON :: struct {
	id:                  int,
	path_with_namespace: string,
	ssh_url_to_repo:     string,
	visibility:          string,
	description:         string,
}

fetch_all_repos :: proc(token: string) -> [dynamic]Repo {
	repos := make([dynamic]Repo)

	page := 1
	per_page := 100

	for {
		url := fmt.tprintf(
			"https://gitlab.com/api/v4/projects?membership=true&per_page=%d&page=%d",
			per_page,
			page,
		)

		headers := make(map[string]string)
		defer delete(headers)
		headers["Private-Token"] = token

		resp, ok := utils.get(url, headers)
		if !ok || resp.status_code != 200 {
			fmt.printf(
				"Failed to fetch GitLab repos (Page %d): Status %d\n",
				page,
				resp.status_code,
			)
			break
		}

		data := transmute([]byte)resp.body

		batch: [dynamic]RepoJSON
		err := json.unmarshal(data, &batch)
		if err != nil {
			fmt.println("JSON Parse Error (GitLab):", err)
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
					id = r.id,
					path_with_namespace = r.path_with_namespace,
					ssh_url_to_repo = r.ssh_url_to_repo,
					visibility = r.visibility,
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

sanitize_name :: proc(name: string) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	for r in name {
		switch r {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-', '.':
			strings.write_rune(&builder, r)
		case:
			strings.write_rune(&builder, '-')
		}
	}
	s := strings.to_string(builder)

	for strings.contains(s, "--") {
		s, _ = strings.replace_all(s, "--", "-")
	}
	for strings.contains(s, "..") {
		s, _ = strings.replace_all(s, "..", ".")
	}
	for strings.contains(s, "__") {
		s, _ = strings.replace_all(s, "__", "_")
	}

	for {
		old_len := len(s)
		s = strings.trim(s, "-_.")
		if strings.has_suffix(s, ".git") {
			s = s[:len(s) - 4]
		} else if strings.has_suffix(s, ".atom") {
			s = s[:len(s) - 5]
		}
		if len(s) == old_len {break}
	}
	return strings.clone(s)
}

create_repo :: proc(
	token: string,
	name: string,
	namespace_id: int = 0,
	visibility: string = "private",
) -> (
	string,
	int,
	bool,
) {
	url := "https://gitlab.com/api/v4/projects"

	headers := make(map[string]string)
	defer delete(headers)
	headers["Private-Token"] = token
	headers["Content-Type"] = "application/json"

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	strings.write_string(&builder, "{")
	strings.write_string(&builder, fmt.tprintf("\"name\": \"%s\",", name))
	strings.write_string(&builder, fmt.tprintf("\"visibility\": \"%s\"", visibility))
	if namespace_id != 0 {
		strings.write_string(&builder, fmt.tprintf(", \"namespace_id\": %d", namespace_id))
	}
	strings.write_string(&builder, "}")

	body := strings.to_string(builder)

	resp, ok := utils.post(url, headers, body)
	if !ok || resp.status_code != 201 {
		fmt.printf("Failed to create GitLab repo '%s': Status %d\n", name, resp.status_code)
		fmt.println(resp.body)
		return "", 0, false
	}
	defer delete(resp.body)

	RespJSON :: struct {
		id:              int,
		ssh_url_to_repo: string,
	}

	data := transmute([]byte)resp.body
	r: RespJSON
	err := json.unmarshal(data, &r)
	if err != nil {
		return "", 0, false
	}

	return r.ssh_url_to_repo, r.id, true
}

unprotect_branch :: proc(token: string, project_id: int, branch_name: string) -> bool {
	url := fmt.tprintf(
		"https://gitlab.com/api/v4/projects/%d/protected_branches/%s",
		project_id,
		branch_name,
	)

	headers := make(map[string]string)
	defer delete(headers)
	headers["Private-Token"] = token

	resp, ok := utils.delete_req(url, headers)
	defer delete(resp.body)
	if !ok {
		return false
	}
	return resp.status_code == 200 || resp.status_code == 204 || resp.status_code == 404
}

unprotect_default_branches :: proc(token: string, project_id: int) {
	unprotect_branch(token, project_id, "main")
	unprotect_branch(token, project_id, "master")
}

protect_branch :: proc(token: string, project_id: int, branch_name: string) -> bool {
	url := fmt.tprintf(
		"https://gitlab.com/api/v4/projects/%d/protected_branches",
		project_id,
	)

	headers := make(map[string]string)
	defer delete(headers)
	headers["Private-Token"] = token
	headers["Content-Type"] = "application/json"

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	strings.write_string(&builder, "{")
	strings.write_string(&builder, fmt.tprintf("\"name\": \"%s\"", branch_name))
	strings.write_string(&builder, "}")

	body := strings.to_string(builder)

	resp, ok := utils.post(url, headers, body)
	defer delete(resp.body)
	if !ok {
		return false
	}
	return resp.status_code == 200 || resp.status_code == 201 || resp.status_code == 409
}

protect_default_branches :: proc(token: string, project_id: int) {
	protect_branch(token, project_id, "main")
	protect_branch(token, project_id, "master")
}


