#! /bin/bash

mode="newest"
ex=false
silent=false
force=false
version=""

log() {
    $silent || echo "$1"
}

while getopts "asmhblfv:" opt; do
  case "$opt" in
        s) # silent
        silent=true
        ;;

        m) # manual
        log "--Using manual mode--"
        mode="manual"
        ;;

        f) # force
        log "--Forcing update--"
        force=true
        ;;

        v) # version
        log "--Setting version--"
        version=$OPTARG
        mode="version"
        ;;

        b) # background
        log "--Running updatego in background--"
        $0 >/dev/null & disown
        ex=true
        ;;

        *) # usage
        echo '
Usage: updatego [options]...

Options
    -a  Setup automatic updates; will execute in the background everytime a new shell is opened
    -l  Setup alias; sets up "updatego" alias
    -m  Manual mode; allows the user to manually specify the version
    -h  Help; shows this help text
    -b  Run in Background; runs the script in the backgorund
    -s  Silent; disables all future console outputs
    -f  Force; forces updating the version, even if it is the same as the current one
    -v  Version; sets the version to use
'
        ex=true
        ;;
    esac
done
if [[ $ex == true ]]; then
    exit 0
fi

# get version
if [[ $mode != "version" ]]; then
    newestVersion=$(go list -m -f '{{.Version}}' go@latest)
    if [[ $mode == "manual" ]]; then
        read -p "Enter version: " -i "$newestVersion" -e version
    else
        currentVersion=$(go version)
        if [[ "$force" == "true" ]]; then
            log "--Forcing update to '$newestVersion'--"
        elif [[ "$currentVersion" == *"$newestVersion"* ]]; then
            log "--Already up to date--"
            exit 0
        else
            log "--Found updated version '$newestVersion'--"
        fi
        version=$newestVersion
    fi
fi

log "--Updating Go to version '$version'--"

goos=$(go env GOOS)
goarch=$(go env GOARCH)
tarName=go$version.$goos-$goarch.tar.gz
tempDir=$(mktemp -d "goupdate-$version-XXXXXXXXXX" -p /tmp) # make temporary directory

log "--Downloading--"
curl -o $tempDir/$tarName -L https://go.dev/dl/$tarName -s # download go

log "--Unpacking--"
sudo tar -C $tempDir -xzf $tempDir/$tarName # unpack tar file

log "--Removing old version--"
sudo rm -rf /usr/local/go # remove old version

log "--Installing--"
sudo mv $tempDir/go /usr/local/go # mv new version to correct location

log "--Removing temporary files--"
rm -rf $tempDir # remove temporary directory

log "--Done--"
