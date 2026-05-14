#+vet
package main

import "config"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "base:runtime"
import "github"
import "gitlab"
import "worker"

foreign import system_c "system:c"

foreign system_c {
	signal :: proc(sig: i32, func: proc "c" (_: i32)) -> rawptr ---
}

SIGINT :: 2

handle_sigint :: proc "c" (sig: i32) {
	if sig == SIGINT {
		worker.stop_pool()
	}
}

main :: proc() {
	signal(SIGINT, handle_sigint)

	args := os.args
	mode := "sync"
	dry_run := false
	threads := 8
	output_dir := "downloaded_repos"

	// Argument parsing
	for i := 1; i < len(args); i += 1 {
		arg := args[i]
		if arg == "--dry-run" {
			dry_run = true
		} else if arg == "--threads" || arg == "-j" {
			if i + 1 < len(args) {
				t, ok := strconv.parse_int(args[i + 1])
				if ok && t > 0 {
					threads = t
					i += 1
				} else {
					fmt.println("Invalid thread count, using default 8")
				}
			}
		} else if arg == "--output-dir" || arg == "-o" {
			if i + 1 < len(args) {
				output_dir = args[i + 1]
				i += 1
			} else {
				fmt.println("Error: Missing argument for --output-dir")
				os.exit(1)
			}
		} else if arg == "download" {
			mode = "download"
		} else if arg == "sync" {
			mode = "sync"
		} else {
			if arg == "--help" || arg == "-h" {
				print_usage()
				return
			}
		}
	}

	fmt.printf("Mode: %s, Dry Run: %t, Threads: %d\n", mode, dry_run, threads)

	// Loading .env (if present)
	if config.load_env(".env") {
		fmt.println("Loaded .env file")
	} else {
		fmt.println("No .env file found or failed to read")
	}

	// GitHub token is required for all operations
	github_token := os.get_env_alloc("GITHUB_TOKEN", runtime.default_allocator())
	if github_token == "" {
		fmt.println("Error: GITHUB_TOKEN is not set")
		os.exit(1)
	}

	current_user, user_ok := github.get_user(github_token)
	if user_ok {
		fmt.printf("Authenticated as GitHub user: %s\n", current_user)
	} else {
		fmt.println("Error: Failed to authenticate with GitHub. Please check your GITHUB_TOKEN.")
		os.exit(1)
	}

	fmt.println("Fetching GitHub repositories...")
	gh_repos := github.fetch_all_repos(github_token)
	defer delete(gh_repos)
	fmt.printf("Found %d repositories on GitHub.\n", len(gh_repos))

	if mode == "download" {
		run_download_mode(gh_repos, current_user, dry_run, threads, output_dir)
	} else if mode == "sync" {
		gitlab_token := os.get_env_alloc("GITLAB_TOKEN", runtime.default_allocator())
		if gitlab_token == "" {
			if !dry_run {
				fmt.println("Error: GITLAB_TOKEN is not set")
				os.exit(1)
			}
			fmt.println("Warning: GITLAB_TOKEN not set, but dry-run matches.")
		}
		run_sync_mode(gh_repos, gitlab_token, current_user, dry_run, threads, output_dir)
	}

	fmt.println("Done.")
}

print_usage :: proc() {
	fmt.println("Usage: hub2lab [command] [options]")
	fmt.println("Commands:")
	fmt.println("  sync          Sync repositories from GitHub to GitLab (default)")
	fmt.println("  download      Download repositories locally")
	fmt.println("Options:")
	fmt.println("  --dry-run      Print actions without executing")
	fmt.println("  --threads, -j  Number of threads to use (default: 8)")
	fmt.println(
		"  --output-dir, -o  Directory to download repositories to (default: downloaded_repos)",
	)
}

run_download_mode :: proc(
	repos: [dynamic]github.Repo,
	current_user: string,
	dry_run: bool,
	threads: int,
	output_dir: string,
) {
	jobs := make([dynamic]worker.Job)
	defer delete(jobs)

	download_dir := output_dir
	if !dry_run {
		os.make_directory(download_dir)
	}

	user_prefix := fmt.tprintf("%s/", current_user)
	if current_user == "" {user_prefix = "NO_USER_PREFIX_MATCH"}

	for gh in repos {
		folder_name := gh.name
		if current_user != "" && !strings.has_prefix(gh.full_name, user_prefix) {
			folder_name = gitlab.sanitize_name(gh.full_name)
		}

		if dry_run {
			fmt.printf(
				"[Dry Run] Would download %s to %s/%s\n",
				gh.name,
				download_dir,
				folder_name,
			)
		} else {
			append(
				&jobs,
				worker.Job {
					type = .Download,
					github_repo_url = gh.ssh_url,
					repo_name = gh.name,
					local_path = fmt.tprintf("%s/%s", download_dir, folder_name),
				},
			)
		}
	}

	if !dry_run && len(jobs) > 0 {
		fmt.printf(
			"Starting download for %d repositories with %d threads...\n",
			len(jobs),
			threads,
		)
		worker.run_pool(jobs, threads)
	}
}

run_sync_mode :: proc(
	repos: [dynamic]github.Repo,
	gitlab_token: string,
	current_user: string,
	dry_run: bool,
	threads: int,
	output_dir: string,
) {
	fmt.println("Fetching GitLab repositories...")
	gl_repos := gitlab.fetch_all_repos(gitlab_token)
	defer delete(gl_repos)
	fmt.printf("Found %d repositories on GitLab.\n", len(gl_repos))

	user_prefix := fmt.tprintf("%s/", current_user)
	if current_user == "" {user_prefix = "NO_USER_PREFIX_MATCH"}

	sync_jobs := make([dynamic]worker.Job)
	defer delete(sync_jobs)

	// Build map for faster lookup
	gl_map := make(map[string]gitlab.Repo)
	defer delete(gl_map)

	for r in gl_repos {
		name := r.path_with_namespace
		if idx := strings.last_index(name, "/"); idx >= 0 {
			name = name[idx + 1:]
		}
		gl_map[name] = r
	}

	// Same sanitization logic as download
	download_dir := output_dir
	if !dry_run {
		os.make_directory(download_dir)
	}

	for gh in repos {
		if current_user != "" && !strings.has_prefix(gh.full_name, user_prefix) {
			if dry_run {
				fmt.printf("[Dry Run] Skipping %s (not owned by %s)\n", gh.full_name, current_user)
			}
			continue
		}

		sanitized_name := gitlab.sanitize_name(gh.name)

		local_folder := gh.name
		if current_user != "" && !strings.has_prefix(gh.full_name, user_prefix) {
			local_folder = gitlab.sanitize_name(gh.full_name)
		}

		found_url := ""
		repo_exists := false

		if r, ok := gl_map[gh.name]; ok {
			found_url = r.ssh_url_to_repo
			repo_exists = true
		} else if r2, ok2 := gl_map[sanitized_name]; ok2 {
			found_url = r2.ssh_url_to_repo
			repo_exists = true
		}

		target_url := found_url

		if !repo_exists {
			create_name := sanitized_name
			if dry_run {
				fmt.printf(
					"[Dry Run] Would create repo %s (as %s) on GitLab (Visibility: %s)\n",
					gh.name,
					create_name,
					gh.private ? "private" : "public",
				)
				target_url = "DRY_RUN_URL"
			} else {
				fmt.printf(
					"Repo %s not found on GitLab. Creating as %s...\n",
					gh.name,
					create_name,
				)
				visibility := "private"
				if !gh.private {visibility = "public"}

				url, ok := gitlab.create_repo(gitlab_token, create_name, 0, visibility)
				if ok {
					fmt.printf("Created %s on GitLab.\n", create_name)
					target_url = url
				} else {
					fmt.printf("Failed to create %s on GitLab. Skipping sync.\n", create_name)
					continue
				}
			}
		} else {
			if dry_run {
				fmt.printf("[Dry Run] Repo %s exists on GitLab.\n", gh.name)
			} else {
				fmt.printf("Repo %s exists on GitLab.\n", gh.name)
			}
		}

		if target_url != "" {
			if dry_run {
				fmt.printf(
					"[Dry Run] Would queue sync %s -> %s (via %s/%s)\n",
					gh.name,
					target_url,
					download_dir,
					local_folder,
				)
			} else {
				append(
					&sync_jobs,
					worker.Job {
						type = .Sync,
						github_repo_url = gh.ssh_url,
						gitlab_repo_url = target_url,
						repo_name = gh.name,
						local_path = fmt.tprintf("%s/%s", download_dir, local_folder),
					},
				)
			}
		}
	}

	if !dry_run && len(sync_jobs) > 0 {
		fmt.printf(
			"Starting sync for %d repositories with %d threads...\n",
			len(sync_jobs),
			threads,
		)
		worker.run_pool(sync_jobs, threads)
	}
}
