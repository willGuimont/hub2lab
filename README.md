# Hub2Lab

Hub2Lab is a tool to manage and sync your GitHub repositories. It can sync them to GitLab (creating missing ones) or download them all locally.

## Prerequisites

- **Git LFS**: Must be installed on your system for repositories using Git LFS to work properly.

## Configuration

Create a `.env` file in the root directory:

```env
GITHUB_TOKEN=your_github_token
GITLAB_TOKEN=your_gitlab_token
```

- `GITHUB_TOKEN` is required for all commands. Needs to have read-only access to your repositories.
- `GITLAB_TOKEN` is required for `sync`. Needs to have read-write access to your repositories.

## Usage

Run the tool using Odin:

```bash
odin run src/main.odin -file -- [command] [options]
```

### Commands

- `sync` (default): Syncs repositories from GitHub to GitLab.
  - Checks existence and creates missing repos on GitLab (Serial, Optimized O(N)).
  - Ensures local repo is up to date (Clone or Pull).
  - Pushes content to GitLab (Parallel).
- `download`: Downloads all repositories locally (Clone or Pull).

### Options

- `--dry-run`: Prints what would happen without performing any write actions (create, clone, push, update).
- `--threads N`, `-j N`: Number of threads to use for parallel operations (default: 8).
- `--output-dir DIR`, `-o DIR`: Directory to download/sync repositories to (default: `downloaded_repos`). Applies to both `sync` and `download`.

### Examples

**Sync all repos with 8 threads:**
```bash
odin run src/main.odin -file -- sync --threads 8
```

**Sync/Download all repos to a specific folder:**
```bash
odin run src/main.odin -file -- sync -o ~/my_backups/github
```

**Dry run check:**
```bash
odin run src/main.odin -file -- sync --dry-run
```
