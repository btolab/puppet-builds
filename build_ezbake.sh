#!/bin/bash

set -e

PROJECTS="${PROJECTS:-puppetserver puppetdb}"
BRANCHES="${BRANCHES:-main 7.x}"
RUBY_VERSION="${RUBY_VERSION:-3.1.2}"
source /etc/os-release

javac -version >/dev/null || sudo -E apt -y install openjdk-17-jdk-headless
cowpoke --version >/dev/null || sudo -E apt -y install devscripts

if ! [ -x /usr/local/bin/lein ] ; then
  wget https://raw.githubusercontent.com/technomancy/leiningen/stable/bin/lein
  chmod +x lein
  sudo cp -f lein /usr/local/bin/lein
fi
lein --version >/dev/null

command -v rbenv >/dev/null || sudo -E apt -y install rbenv
eval "$(rbenv init -)"

## build

for PROJECT in $PROJECTS ; do
  [ -d ${PROJECT}/.git ] || git clone https://github.com/puppetlabs/${PROJECT}.git
  pushd ${PROJECT} >/dev/null

  if ! rbenv local ${RUBY_VERSION} ; then
    rbenv install ${RUBY_VERSION}
    rbenv local ${RUBY_VERSION}
  fi

  for BRANCH in $BRANCHES ; do
      echo "**> ${PROJECT}/${BRANCH}"
      git reset --hard origin/${BRANCH}

      export GEM_SOURCE="https://rubygems.org"
      export MOCK=""
      export COW="base-${VERSION_CODENAME}-all.cow"
      export EZBAKE_ALLOW_UNREPRODUCIBLE_BUILDS=true
      export EZBAKE_NODEPLOY=true
      export DEBIAN_FRONTEND=noninteractive

      lein clean && lein install && lein with-profile ezbake,provided ezbake local-build
  done

  popd >/dev/null
done
