#!/bin/bash
# Script to set up a datalad dataset for public  and internal sharing.
#
# 
# Instructions to setup datalad once; before running this script.
#  On a Linux install (or a WSL2 in Windows)
#  1. install datalad  from neurodebian 
#  2. Configure git user.name and user.email , setup credential caching
#  3. install rclone (sudo apt install rclone)
#  4. rclone config to target the KLab Annex SharedFolder on Google Drive as klabAnnex
#  5. wget https://raw.githubusercontent.com/DanielDent/git-annex-remote-rclone/master/git-annex-remote-rclone  -O ~/.local/bin
#
#
# BK - November 2021


NAME="myProject2"
ANNEX="klabAnnex"
ORG="klabhub"
USER="bartkrekelberg"

# Setup the top level dataset. Its name will be ds.NAME
datalad create -c text2git "ds.$NAME"
cd "ds.$NAME"

cat << EOF > README.md
## Project $NAME

This repository contains a publically available dataset. Its contents can be
retrieved using datalad (https://www.datalad.org) with 
```datalad clone  https://github.com/$ORG/ds.$NAME.git 

Some parts of this project are for lab internal use only (the ```./internal``` folder). 
Datalad will not be able to ```datalad get``` those files without special permission from $USER.

EOF

# Add an rclone remote to annex in GDrive (or whateve ANNEX points to in rclone; use rclone config to set this up manually)
git annex initremote $ANNEX type=external externaltype=rclone chunk=50MiB encryption=none target=$ANNEX prefix=$NAME
datalad create-sibling-github --github-organization $ORG --private --publish-depends $ANNEX --github-login $USER --access-protocol ssh "ds.$NAME"

# Create folders for data and derivatives that will be shared (at least eventually,once the github repo is made public, and the annex gives read access to the world)
mkdir derivatives
mkdir bids   
mkdir code

# Add an internalfor data that cannot/should not be shared. This is a subdataset.
datalad create -c text2git  -d . internal
cd internal
cat << EOF > README.md
## Project $NAME - Internal files

This repository contains a the internal files for ds.$NAME.

All raw (non-defaced) imaging data, any data with PHI, and any development phase source code
are stored in this internal repository/dataset. 

The repository is stored privately on Github:
https://github.com/$ORG/ds.$NAME.internal.git 
and the annex is on a Google Drive Share with restricted access.

This dataset can only be shared with people on the IRB protocol.
 
EOF

git annex initremote "$ANNEX.internal" type=external externaltype=rclone chunk=50MiB encryption=none target=$ANNEX prefix="$NAME/internal"
datalad create-sibling-github --github-organization $ORG --private --publish-depends "$ANNEX.internal" --github-login $USER --access-protocol ssh "ds.$NAME.internal"
mkdir code
mkdir derivatives

datalad save -m "Initial setup of internal dataset"
datalad push --to github

cd ..
datalad save -m "Initial setup of public dataset"
datalad push --to github



