#!/bin/bash

git fetch upstream
git checkout main
git pull --rebase upstream main

if [[ $# -eq 0 ]] ; then
	exit 1
fi

git checkout $1
git rebase main
