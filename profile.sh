#!/bin/bash

# A helper script to profile an application using macOS system tools.

rm -f profile.plist
touch profile.plist
echo '<?xml version="1.0" encoding="UTF-8"?>' >> profile.plist
echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> profile.plist
echo '<plist version="1.0">' >> profile.plist
echo '	<dict>' >> profile.plist
echo '	    <key>com.apple.security.get-task-allow</key>' >> profile.plist
echo '	    <true/>' >> profile.plist
echo '	</dict>' >> profile.plist
echo '</plist>' >> profile.plist

echo "Signing..."
codesign -s - -v -f --entitlements profile.plist $2

echo "Doing trace..."
rm -rf profile.trace
TEMPLATE="$1"
shift
xctrace record --template $TEMPLATE --output 'profile.trace' --target-stdout - --launch -- $@

echo "Cleaning up..."
rm -f profile.plist

echo "Launching Instruments..."
open profile.trace 
