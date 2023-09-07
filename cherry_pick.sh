#!/bin/bash

if [ -n "$DEBUG" ] || [[ "$1" == "-v" || "$1" == "--verbose" ]]; then
	set -x
fi

set -Eeuo pipefail

# Check for help flag
if [ -n "${1-}" ] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
	echo "Usage: bin/deploy [OPTIONS]"
	echo
	echo "Options:"
	echo "  -h, --help     Show this help message and exit"
	echo "  -v, --verbose  Enable verbose output"
	exit 0
fi

CHANGES=false
COMMITS=0
PICK_ERRORS=false
GIT_LOG_ERRORS=false

cherry_pick_sha() {
	local arg="${1}"
	if [ -n "$arg" ] && [ "$arg" != "q" ]; then
		PICK_ERRORS=true
		git cherry-pick "$arg"
		PICK_ERRORS=false
		CHANGES=true
		COMMITS=$((COMMITS + 1))
	fi
}

add_upstream_ssh() {
	echo "This script expects that you've added a git remote named 'upstream'."
	echo "Would you like to add an 'upstream' remote using the following command?"
	echo
	echo "git remote add upstream REPO_GIT_URI"
	echo
	read -p "You will need to connect to Github through SSH. Are you sure you want to proceed? (y/n) " -r
	if [[ ! $REPLY =~ ^[Yy]$ ]]
	then
		exit 1
	fi
	echo "Please visit the following to learn more about SSH remotes and Github: https://docs.github.com/en/authentication/connecting-to-github-with-ssh"
	git remote add upstream REPO_GIT_URI
}

catch_errors() {
	if [[ "$PICK_ERRORS" == true ]]; then
		echo
		echo "Script exited while trying to 'cherry-pick' a commit."
		echo "Here are two typical causes for that:"
		echo
		echo "1. The SHA can't be found. Here's an example output: 'fatal: bad revision <SHA>'"
		echo "2. There was a conflict trying to merge the commit. Example: 'CONFLICT (content): Merge conflict in bin/deploy'"
		echo
		echo "These will require some troubleshooting that will be unique to your env and the commits you're trying to work with."
		echo "If you're experiencing 'bad revision', try fetching from remote branches that may have the commit you're after."
		echo "It's also possible that the commit you copied was later revised through a force-push to whatever branch or fork."
		echo "In that case, the fix may be as simple as finding the new commit SHA by refreshing a stale commits page."
		echo
		echo "In the case of a merge conflict, this will require resolving the conflict manually."
		echo "Github provides a guide for resolving merge conflicts, here:"
		echo "https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/addressing-merge-conflicts/resolving-a-merge-conflict-on-github"
		echo
		echo "IMPORTANT: Any conflicts will need to be fixed before you push your changes."
		echo "Since the script exited early, you will need to manually push your resolved changes to your target branch."
		echo
		echo "ALSO IMPORTANT: Rerunning the script and hard resetting your target branch will require you to cherry-pick"
		echo "all your commits again; including any you cherry-picked before the error caused the script to exit."
	fi

	if [[ "$GIT_LOG_ERRORS" == true ]]; then
		echo
		echo "Script exited while trying to retrieve commits from your dev branch."
		echo "If you see output like 'fatal: ambiguous argument', it is likely because no branch was found with the branch name you supplied."
		echo
		echo "Ensure that the branch name was spelled correctly (with no quotes!)"
	fi
}

trap 'catch_errors' ERR

# Detect if upstream in remotes, present options if not.
remote=$(git remote | grep "^upstream$" || true)

if [ -n "$remote" ]; then
	upstream_url=$(git remote get-url upstream)
	if [[ $upstream_url == "REPO_GIT_URI" ]] || [[ $upstream_url == "REPO_GIT_URI_http" ]]; then
		echo "Remote 'upstream' exists."
	else
		echo "Your 'upstream' remote doesn't point to either the SSH or HTTPS URL for getflywheel (i.e. REPO_GIT_URI or REPO_GIT_URI_http)."
		add_upstream_ssh
	fi
else
	remote=$(git remote | grep "^origin$" || true)
	if [ -n "$remote" ]; then
		origin_url=$(git remote get-url origin)
		if [[ -n "$origin_url" ]] && [[ $origin_url == "REPO_GIT_URI" ]]; then
			echo "This script expects that you have a git remote named 'upstream' pointed at 'REPO_GIT_URI'."
			echo "You have a remote named 'origin' pointed there instead."
			echo "Would you like to rename that 'origin' remote to 'upstream' using the following command?"
			echo
			echo "git remote rename origin upstream"
			echo
			read -p "Proceed? (y/n) " -r
			if [[ ! $REPLY =~ ^[Yy]$ ]]
			then
				exit 1
			fi
			git remote rename origin upstream
		else
			add_upstream_ssh
		fi
	else
		add_upstream_ssh
	fi
fi

# Set target deploy branch
echo "Fetching 'upstream'..."
git fetch upstream

current_branch=$(git rev-parse --abbrev-ref HEAD)
default_target_branch="DEFAULT_BRANCH"

if [[ $current_branch != "$default_target_branch" ]]; then
	echo "Currently on $current_branch."
fi

echo "Input a target branch to deploy, or hit 'return' to default to '$default_target_branch': "
read -r target_branch

if [ -z "$target_branch" ]; then
	target_branch="$default_target_branch"
fi

if [[ $current_branch != "$target_branch" ]]; then
	git checkout $target_branch
fi

current_branch=$(git rev-parse --abbrev-ref HEAD)

# Reset hard unless the branch is already up-to-date with its upstream counterpart.
if git status | grep -q "Your branch is up to date with 'upstream/$current_branch'."; then
	echo "$current_branch is up-to-date with upstream."
else
	echo
	echo "This script will HARD reset your local $current_branch to the upstream branch of the same name."

	read -p "Are you sure you want to proceed? (y/n) " -r
	if [[ ! $REPLY =~ ^[Yy]$ ]]
	then
		exit 1
	fi

	git reset --hard upstream/"$current_branch"
fi

# Grab the last N commit SHAs from the local dev branch and apply them at once
do_manual_entry=true
echo
read -p "Specify a local branch name to cherry-pick the top {N} stack of commits from it (leave blank to cherry-pick individual commits): " dev_branch
if [ -n "$dev_branch" ] && ! [ "$dev_branch" == "" ]; then
	read -p "How many commits do you want to include? " n_commits
	echo
	GIT_LOG_ERRORS=true
	commit_shas=$(git log -${n_commits} --format="%H" --reverse ${dev_branch} | xargs echo -n)
	echo "You've selected the following commits:"
	echo
	git --no-pager log -${n_commits} --format="%s" ${dev_branch}
	GIT_LOG_ERRORS=false
	echo
	read -p "Is this correct? (y/n) " confirmation

	if [[ ! $confirmation =~ ^[Yy]$ ]]; then
		echo "Continuing to manual SHA entry..."
	else
		PICK_ERRORS=true
		git cherry-pick $commit_shas
		PICK_ERRORS=false
		CHANGES=true
		COMMITS=$n_commits
		do_manual_entry=false
	fi
fi

# Do the whole cherry-pick dance!
echo
if [[ "$do_manual_entry" == true ]]; then
	read -r -p "Copy/paste your git commit SHA to cherry-pick it onto $current_branch (enter 'q' to skip): " sha
	cherry_pick_sha "$sha"
	until [ "$sha" == "q" ]; do
		read -r -p "$COMMITS commits cherry-picked. Copy/paste your next SHA (enter 'q' to skip): " sha
		cherry_pick_sha "$sha"
	done
fi

# Bombs away!
echo
if [[ "$CHANGES" == true ]]; then
	echo "Pushing changes to $current_branch!"
	git push upstream "$current_branch"
	echo
	if [[ $current_branch == "$default_target_branch" ]]; then
		echo "Default branch succcess"
	else
		echo "$current_branch success"
	fi
else
	echo "No changes staged for deployment, exiting."
fi
