#!/bin/env bash

if [ -z "$1" ]
then
  echo "WGET and Extract a tarball file all in one step"
  echo "  USAGE: ${0} tarball-url [destination]"
else
  if [ -z "$2" ]
  then
    wget -O - $1 | tar zxv
  else
    wget -O - $1 | tar zxv -C $2
  fi
fi
