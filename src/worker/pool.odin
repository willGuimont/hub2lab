#+vet
package worker

import "base:intrinsics"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"

foreign import system_c "system:c"

foreign system_c {
	fork :: proc() -> i32 ---
	execvp :: proc(file: cstring, argv: ^cstring) -> i32 ---
	waitpid :: proc(pid: i32, status: ^i32, options: i32) -> i32 ---
	exit :: proc(status: i32) -> ! ---
}

import "../gitlab"

JobType :: enum {
	Sync,
	Download,
}

Job :: struct {
	type:              JobType,
	github_repo_url:   string,
	gitlab_repo_url:   string,
	repo_name:         string,
	local_path:        string,
	gitlab_token:      string,
	gitlab_project_id: int,
}

Pool :: struct {
	jobs:           [dynamic]Job,
	job_mutex:      sync.Mutex,
	results_mutex:  sync.Mutex,
	errors:         [dynamic]string,
	active_threads: int,
	should_stop:    b32,
}

// Global pointer for signal handler
global_pool_ptr: ^Pool

stop_pool :: proc "contextless" () {
	if global_pool_ptr != nil {
		intrinsics.atomic_store(&global_pool_ptr.should_stop, true)
	}
}

git_exec :: proc(args: []string) -> bool {
	argv := make([dynamic]cstring)
	defer delete(argv)

	cmd := strings.clone_to_cstring("git")
	append(&argv, cmd)

	defer delete(cmd)

	cloned_args := make([dynamic]cstring)
	defer delete(cloned_args)
	defer {
		for s in cloned_args {
			delete(s)
		}
	}

	for arg in args {
		s := strings.clone_to_cstring(arg)
		append(&cloned_args, s)
		append(&argv, s)
	}
	append(&argv, nil)

	pid := fork()
	if pid < 0 {
		return false // Fork failed
	}

	if pid == 0 {
		execvp(argv[0], raw_data(argv))
		fmt.eprintln("Failed to exec git")
		exit(1)
	}

	// Parent
	status: i32
	waitpid(pid, &status, 0)

	return status == 0
}

WorkerArgs :: struct {
	pool: ^Pool,
	id:   int,
}

import "core:os"

is_git_repo :: proc(path: string) -> bool {
	git_path := fmt.tprintf("%s/.git", path)
	return os.exists(git_path)
}

is_lfs_repo :: proc(path: string) -> bool {
	lfs_dir := fmt.tprintf("%s/.git/lfs", path)
	if os.exists(lfs_dir) {
		return true
	}

	gitattributes_path := fmt.tprintf("%s/.gitattributes", path)
	if os.exists(gitattributes_path) {
		data, err := os.read_entire_file_from_path(gitattributes_path, context.temp_allocator)
		if err == nil {
			if strings.contains(string(data), "filter=lfs") {
				return true
			}
		}
	}

	return false
}

// Helper wrapper to ignore errors
git_exec_ignore_error :: proc(args: []string) {
	// Just reuse the main implementation and ignore result
	git_exec(args)
}

ensure_local_repo :: proc(j: Job, thread_id: int) -> bool {
	if is_git_repo(j.local_path) {
		fmt.printf("[Thread %d] Updating %s...\n", thread_id, j.repo_name)
		if !git_exec([]string{"-C", j.local_path, "pull"}) {
			fmt.printf(
				"[Thread %d] Failed to pull %s (might be dirty or diverged). Continuing anyway.\n",
				thread_id,
				j.repo_name,
			)
		}

		// Also fetch everything and prune deleted branches to be a perfect mirror source
		if !git_exec([]string{"-C", j.local_path, "fetch", "origin", "--prune"}) {
			fmt.printf("[Thread %d] Failed to fetch prune %s\n", thread_id, j.repo_name)
		} else {
			fmt.printf("[Thread %d] Successfully updated %s\n", thread_id, j.repo_name)
		}

		return true
	} else {
		fmt.printf("[Thread %d] Cloning %s to %s...\n", thread_id, j.repo_name, j.local_path)
		if !git_exec([]string{"clone", j.github_repo_url, j.local_path}) {
			fmt.printf("[Thread %d] Failed to clone %s\n", thread_id, j.repo_name)
			return false
		}
		fmt.printf("[Thread %d] Successfully cloned %s\n", thread_id, j.repo_name)
		return true
	}
}

download_repo :: proc(j: Job, thread_id: int) {
	if ensure_local_repo(j, thread_id) {
		if is_lfs_repo(j.local_path) {
			fmt.printf("[Thread %d] Git LFS detected in %s. Fetching LFS objects...\n", thread_id, j.repo_name)
			git_exec_ignore_error([]string{"-C", j.local_path, "lfs", "fetch", "--all"})
		}
	}
}

sync_repo :: proc(j: Job, thread_id: int) {
	fmt.printf("[Thread %d] Syncing %s...\n", thread_id, j.repo_name)

	if j.gitlab_token != "" && j.gitlab_project_id != 0 {
		gitlab.unprotect_default_branches(j.gitlab_token, j.gitlab_project_id)
		defer gitlab.protect_default_branches(j.gitlab_token, j.gitlab_project_id)
	}

	if !ensure_local_repo(j, thread_id) {
		fmt.printf(
			"[Thread %d] Skipping sync for %s due to checkout failure\n",
			thread_id,
			j.repo_name,
		)
		return
	}

	// Detect and push LFS objects if repo uses Git LFS
	if is_lfs_repo(j.local_path) {
		fmt.printf("[Thread %d] Git LFS detected in %s. Fetching and pushing LFS objects...\n", thread_id, j.repo_name)
		git_exec_ignore_error([]string{"-C", j.local_path, "lfs", "fetch", "--all"})
		if !git_exec([]string{"-C", j.local_path, "lfs", "push", "--all", j.gitlab_repo_url}) {
			fmt.printf("[Thread %d] Warning: Failed to push LFS objects for %s\n", thread_id, j.repo_name)
		}
	}

	// 1. Delete local HEAD symref for origin
	git_exec_ignore_error([]string{"-C", j.local_path, "remote", "set-head", "origin", "-d"})

	// 2. Push tags
	git_exec_ignore_error(
		[]string {
			"-C",
			j.local_path,
			"push",
			"--force",
			j.gitlab_repo_url,
			"refs/tags/*:refs/tags/*",
		},
	)

	// 3. Push all remote branches to heads
	if !git_exec(
		[]string {
			"-C",
			j.local_path,
			"push",
			"--force",
			j.gitlab_repo_url,
			"refs/remotes/origin/*:refs/heads/*",
		},
	) {
		fmt.printf("[Thread %d] Failed to push %s to GitLab\n", thread_id, j.repo_name)
	} else {
		fmt.printf("[Thread %d] Successfully synced %s to GitLab\n", thread_id, j.repo_name)
	}
}

worker_proc :: proc(t: ^thread.Thread) {
	args := cast(^WorkerArgs)t.data
	p := args.pool
	id := args.id

	for {
		sync.mutex_lock(&p.job_mutex)
		if len(p.jobs) == 0 {
			sync.mutex_unlock(&p.job_mutex)
			break
		}

		job := p.jobs[0]
		ordered_remove(&p.jobs, 0)
		sync.mutex_unlock(&p.job_mutex)

		switch job.type {
		case .Sync:
			sync_repo(job, id)
		case .Download:
			download_repo(job, id)
		}

		if intrinsics.atomic_load(&p.should_stop) {
			fmt.printf("[Thread %d] Stopping due to signal...\n", id)
			break
		}
	}

	free(args)
}

run_pool :: proc(jobs: [dynamic]Job, num_threads: int) {
	p: Pool
	p.jobs = jobs
	global_pool_ptr = &p

	pool_threads := make([dynamic]^thread.Thread)
	defer delete(pool_threads)

	for i in 0 ..< num_threads {
		t := thread.create(worker_proc)

		args := new(WorkerArgs)
		args.pool = &p
		args.id = i + 1
		t.data = args

		append(&pool_threads, t)
		thread.start(t)
	}

	for t in pool_threads {
		thread.join(t)
		thread.destroy(t)
	}
}
