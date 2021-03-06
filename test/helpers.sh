#!/bin/sh

set -e -u

set -o pipefail

resource_dir=/opt/resource

run() {
  export TMPDIR=$(mktemp -d ${TMPDIR_ROOT}/git-tests.XXXXXX)

  echo -e 'running \e[33m'"$@"$'\e[0m...'
  eval "$@" 2>&1 | sed -e 's/^/  /g'
  echo ""
}

load_pubkey() {
  local private_key_path=$1
  local hostname=$2

  if [ -s $private_key_path ]; then
    chmod 0600 $private_key_path
    mkdir -p ~/.ssh
    cat > ~/.ssh/config <<EOF
StrictHostKeyChecking no
LogLevel quiet
Host $hostname
    KexAlgorithms +diffie-hellman-group1-sha1
EOF
    chmod 0600 ~/.ssh/config

    eval $(ssh-agent) >/dev/null 2>&1
    trap "kill $SSH_AGENT_PID" 0

    SSH_ASKPASS=${resource_dir}/askpass.sh DISPLAY= ssh-add $private_key_path >/dev/null
  fi
}

init_repo() {
  (
    set -e

    cd $(mktemp -d $TMPDIR/XXXXXX)

    local hostname=$1
    local project=$2
    local username=$3
    # cd ..
    # rm -rf $project
    # ssh -p 29418 $username@$hostname gerrit create-project $project --empty-commit

    git clone ssh://$username@$hostname:29418/$project

    cd $project
    gitdir=$(git rev-parse --git-dir); scp -p -P 29418 $username@$hostname:hooks/commit-msg ${gitdir}/hooks/
    # TFILE="testfile$$.txt"
    # date > $TFILE
    # git add $TFILE

    # start with an initial commit
    # git commit -q -m "My pretty test commit"

    # create some bogus branch
    # git checkout -b bogus

    # git commit -q -m "commit on other branch"

    # push to a gerrit virtual branch for bogus (virtual branches are for: "code review before submission to branch")
    # git push origin HEAD:refs/for/bogus

    # back to master
    # git checkout master

    # push to a gerrit virtual branch for master
    # git push origin HEAD:refs/for/master

    # print resulting repo
    pwd
  )
}

init_repo_with_submodule() {
  local submodule=$(init_repo)
  make_commit $submodule >/dev/null
  make_commit $submodule >/dev/null

  local project=$(init_repo)
  git -C $project submodule add "file://$submodule" >/dev/null
  git -C $project commit -m "Adding Submodule" >/dev/null
  echo $project,$submodule
}

make_commit_to_file_on_branch() {
  local repo=$1
  local file=$2
  local branch=$3
  local msg=${4-}

  # ensure branch exists
  if ! git -C $repo rev-parse --verify $branch >/dev/null; then
    git -C $repo branch $branch master
  fi

  # switch to branch
  git -C $repo checkout -q $branch

  # modify file and commit
  echo x >> $repo/$file
  git -C $repo add $file
  git -C $repo commit -q -m "commit $(wc -l $repo/$file) $msg"

  git -C $repo push origin HEAD:refs/for/master

  # output resulting sha
  git -C $repo rev-parse HEAD
}

make_commit_to_file() {
  make_commit_to_file_on_branch $1 $2 master "${3-}"
}

make_commit_to_branch() {
  make_commit_to_file_on_branch $1 some-file $2
}

make_commit() {
  make_commit_to_file $1 some-file "${2:-}"
}

make_commit_to_be_skipped() {
  make_commit_to_file $1 some-file "[ci skip]"
}

make_empty_commit() {
  local repo=$1
  local msg=${2-}

  git -C $repo \
    -c user.name='test' \
    -c user.email='test@example.com' \
    commit -q --allow-empty -m "commit $msg"

  # output resulting sha
  git -C $repo rev-parse HEAD
}

make_annotated_tag() {
  local repo=$1
  local tag=$2
  local msg=$3

  git -C $repo tag -a "$tag" -m "$msg"

  git -C $repo describe --tags --abbrev=0
}

check_uri() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .)
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

check_gerrit_resource() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      hostname: $(echo $2 | jq -R .),
      project: $(echo $3 | jq -R .),
      username: $(echo $4 | jq -R .),
      private_key: $(cat $5 | jq -s -R .)
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

get_initial_ref() {
  local repo=$1

  git -C $repo rev-list HEAD | tail -n 1
}

check_uri_with_key() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      private_key: $(cat $2 | jq -s -R .)
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

check_uri_with_credentials() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      username: $(echo $2 | jq -R .),
      password: $(echo $3 | jq -R .)
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}


check_uri_ignoring() {
  local uri=$1

  shift

  jq -n "{
    source: {
      uri: $(echo $uri | jq -R .),
      ignore_paths: $(echo "$@" | jq -R '. | split(" ")')
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

check_uri_paths() {
  local uri=$1

  shift

  jq -n "{
    source: {
      uri: $(echo $uri | jq -R .),
      paths: $(echo "$@" | jq -R '. | split(" ")')
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

check_uri_paths_ignoring() {
  local uri=$1
  local paths=$2

  shift 2

  jq -n "{
    source: {
      uri: $(echo $uri | jq -R .),
      paths: [$(echo $paths | jq -R .)],
      ignore_paths: $(echo "$@" | jq -R '. | split(" ")')
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

check_uri_from() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .)
    },
    version: {
      ref: $(echo $2 | jq -R .)
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

check_uri_from_ignoring() {
  local uri=$1
  local ref=$2

  shift 2

  jq -n "{
    source: {
      uri: $(echo $uri | jq -R .),
      ignore_paths: $(echo "$@" | jq -R '. | split(" ")')
    },
    version: {
      ref: $(echo $ref | jq -R .)
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

check_uri_from_paths() {
  local uri=$1
  local ref=$2

  shift 2

  jq -n "{
    source: {
      uri: $(echo $uri | jq -R .),
      paths: $(echo "$@" | jq -R '. | split(" ")')
    },
    version: {
      ref: $(echo $ref | jq -R .)
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

check_uri_from_paths_ignoring() {
  local uri=$1
  local ref=$2
  local paths=$3

  shift 3

  jq -n "{
    source: {
      uri: $(echo $uri | jq -R .),
      paths: [$(echo $paths | jq -R .)],
      ignore_paths: $(echo "$@" | jq -R '. | split(" ")')
    },
    version: {
      ref: $(echo $ref | jq -R .)
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

check_uri_with_tag_filter() {
  local uri=$1
  local tag_filter=$2
  jq -n "{
    source: {
      uri: $(echo $uri | jq -R .),
      tag_filter: $(echo $tag_filter | jq -R .)
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

check_uri_with_tag_filter_from() {
  local uri=$1
  local tag_filter=$2
  local ref=$3

  jq -n "{
    source: {
      uri: $(echo $uri | jq -R .),
      tag_filter: $(echo $tag_filter | jq -R .)
    },
    version: {
      ref: $(echo $ref | jq -R .)
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

check_uri_with_config() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      git_config: [
        {
          name: \"core.pager\",
          value: \"true\"
        },
        {
          name: \"credential.helper\",
          value: \"!true long command with variables \$@\"
        }
      ]
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

check_uri_disable_ci_skip() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      disable_ci_skip: true
    },
    version: {
      ref: $(echo $2 | jq -R .)
    }
  }" | ${resource_dir}/check | tee /dev/stderr
}

get_uri() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .)
    }
  }" | ${resource_dir}/in "$2" | tee /dev/stderr
}

get_uri_at_depth() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .)
    },
    params: {
      depth: $(echo $2 | jq -R .)
    }
  }" | ${resource_dir}/in "$3" | tee /dev/stderr
}

get_uri_with_submodules_at_depth() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .)
    },
    params: {
      depth: $(echo $2 | jq -R .),
      submodules: [$(echo $3 | jq -R .)],
    }
  }" | ${resource_dir}/in "$4" | tee /dev/stderr
}

get_uri_with_submodules_all() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .)
    },
    params: {
      depth: $(echo $2 | jq -R .),
      submodules: \"all\",
    }
  }" | ${resource_dir}/in "$3" | tee /dev/stderr
}

get_uri_at_ref() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .)
    },
    version: {
      ref: $(echo $2 | jq -R .)
    }
  }" | ${resource_dir}/in "$3" | tee /dev/stderr
}

get_uri_at_branch() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      branch: $(echo $2 | jq -R .)
    }
  }" | ${resource_dir}/in "$3" | tee /dev/stderr
}

get_uri_with_config() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      git_config: [
        {
          name: \"core.pager\",
          value: \"true\"
        },
        {
          name: \"credential.helper\",
          value: \"!true long command with variables \$@\"
        }
      ]
    }
  }" | ${resource_dir}/in "$2" | tee /dev/stderr
}


put_uri() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      branch: \"master\"
    },
    params: {
      repository: $(echo $3 | jq -R .)
    }
  }" | ${resource_dir}/out "$2" | tee /dev/stderr
}

put_uri_with_only_tag() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      branch: \"master\"
    },
    params: {
      repository: $(echo $3 | jq -R .),
      only_tag: true
    }
  }" | ${resource_dir}/out "$2" | tee /dev/stderr
}

put_uri_with_rebase() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      branch: \"master\"
    },
    params: {
      repository: $(echo $3 | jq -R .),
      rebase: true
    }
  }" | ${resource_dir}/out "$2" | tee /dev/stderr
}

put_uri_with_tag() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      branch: \"master\"
    },
    params: {
      tag: $(echo $3 | jq -R .),
      repository: $(echo $4 | jq -R .)
    }
  }" | ${resource_dir}/out "$2" | tee /dev/stderr
}

put_uri_with_tag_and_prefix() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      branch: \"master\"
    },
    params: {
      tag: $(echo $3 | jq -R .),
      tag_prefix: $(echo $4 | jq -R .),
      repository: $(echo $5 | jq -R .)
    }
  }" | ${resource_dir}/out "$2" | tee /dev/stderr
}

put_uri_with_tag_and_annotation() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      branch: \"master\"
    },
    params: {
      tag: $(echo $3 | jq -R .),
      annotate: $(echo $4 | jq -R .),
      repository: $(echo $5 | jq -R .)
    }
  }" | ${resource_dir}/out "$2" | tee /dev/stderr
}

put_uri_with_rebase_with_tag() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      branch: \"master\"
    },
    params: {
      tag: $(echo $3 | jq -R .),
      repository: $(echo $4 | jq -R .),
      rebase: true
    }
  }" | ${resource_dir}/out "$2" | tee /dev/stderr
}

put_uri_with_rebase_with_tag_and_prefix() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      branch: \"master\"
    },
    params: {
      tag: $(echo $3 | jq -R .),
      tag_prefix: $(echo $4 | jq -R .),
      repository: $(echo $5 | jq -R .),
      rebase: true
    }
  }" | ${resource_dir}/out "$2" | tee /dev/stderr
}

put_uri_with_config() {
  jq -n "{
    source: {
      uri: $(echo $1 | jq -R .),
      branch: \"master\",
      git_config: [
        {
          name: \"core.pager\",
          value: \"true\"
        },
        {
          name: \"credential.helper\",
          value: \"!true long command with variables \$@\"
        }
      ]
    },
    params: {
      repository: $(echo $3 | jq -R .)
    }
  }" | ${resource_dir}/out "$2" | tee /dev/stderr
}
