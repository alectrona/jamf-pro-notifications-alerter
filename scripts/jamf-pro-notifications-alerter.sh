#!/bin/bash

# Jamf Pro Notifications Alerter
# Written by Ryan Ball and Sam Gibbs @ Alectrona

# Jamf Pro API Reference - Get Notifications for user and site
# https://developer.jamf.com/jamf-pro/reference/get_v1-notifications

jamfProURL="$JAMF_PRO_URL"
apiUser="$API_USER"
apiPass="$API_PASS"
slackWebhook="$SLACK_WEBHOOK"
jamfProDomain=$(awk -F/ '{print $3}' <<< "$jamfProURL")
unameType=$(uname -s)
selectedNotificationsFile="notifications.txt"
index="0"
notificationCount="0"
notificationStrings=()

unset apiToken jamfProNotifications notificationType notificationParamName notificationParamDays notificationString notificationStringsDelimited slackPayload

# Expire the Bearer Token
function finish() {
    [[ -n "$apiToken" ]] && curl -s -H "Authorization: Bearer $apiToken" "$jamfProURL/uapi/auth/invalidateToken" -X POST
}
trap "finish" EXIT

# Function to get a Jamf Pro API Bearer Token
function get_jamf_pro_api_token() {
    local healthCheckHttpCode validityHttpCode

    # Make sure we can contact the Jamf Pro server
    healthCheckHttpCode=$(curl -s "${jamfProURL}/healthCheck.html" -X GET -o /dev/null -w "%{http_code}")
    [[ "$healthCheckHttpCode" != "200" ]] && echo "Unable to contact the Jamf Pro server; exiting" && exit 4

    # Attempt to obtain the token
    apiToken=$(curl -s -u "$apiUser:$apiPass" "${jamfProURL}/api/v1/auth/token" -X POST 2>/dev/null | jq -r '.token | select(.!=null)')
    [[ -z "$apiToken" ]] && echo "Unable to obtain a Jamf Pro API Bearer Token; exiting" && exit 5

    # Validate the token
    validityHttpCode=$(curl -s -H "Authorization: Bearer $apiToken" "${jamfProURL}/api/v1/auth" -X GET -o /dev/null -w "%{http_code}")
    [[ "$validityHttpCode" != "200" ]] && exit 6

    return
}

show_help() {
    local exitCode="$1"

    echo
    /bin/cat << HELP
OVERVIEW: A tool that retrieves Jamf Pro Notifications and posts them to Slack.

USAGE:
./jamf-pro-notifications-alerter.sh [--url] [--username] [--password] [--slack-webhook]

OPTIONS: 

--url               The Jamf Pro URL.
--username          The Jamf Pro API username.
--password          The Jamf Pro API password.
--slack-webhook     A Slack webhook to post the Jamf Pro Notifications to.

ENVIRONMENTAL VARIABLES:

The below Environmental Variables can be used in place of command line options.

JAMF_PRO_URL
API_USER
API_PASS
SLACK_WEBHOOK

Note: Using any of the above command line options will override that option's associated
environmental variable.

HELP
    exit "$exitCode"
}

# Determine if we have jq installed, and exit if not
if ! command -v jq > /dev/null ; then
    echo "Error: jq is not installed, can't continue."

    if [[ "$unameType" == "Darwin" ]]; then
        echo "Suggestion: Install jq with Homebrew: \"brew install jq\""
    else
        echo "Suggestion: Install jq with your distro's package manager."
    fi

    exit 1
fi

# Parse our command line arguments
while test $# -gt 0
do
    case "$1" in
        --url)
            shift
            jamfProURL="${1%/}"
            ;;
        --username)
            shift
            apiUser="$1"
            ;;
        --password)
            shift
            apiPass="$1"
            ;;
        --slack-webhook)
            shift
            slackWebhook="$1"
            ;;
        --help)
            show_help 0
            ;;
        *)
            # Exit if we received an unknown option/flag/argument
            [[ "$1" == --* ]] && echo "Error: Unknown option/flag: $1" && show_help 2
            [[ "$1" != --* ]] && echo "Error: Unknown argument: $1" && show_help 2
            ;;
    esac
    shift
done

# Exit if our arguments are not set
[[ -z "$jamfProURL" ]] && echo "Error: Jamf Pro URL is not set." && show_help 2
[[ -z "$apiUser" ]] && echo "Error: API User is not set." && show_help 2
[[ -z "$apiPass" ]] && echo "Error: API Pass is not set." && show_help 2
[[ -z "$slackWebhook" ]] && echo "Error: Slack Webhook is not set." && show_help 2

# Get our Jamf Pro API Bearer Token
get_jamf_pro_api_token

# Returns notifications from Jamf Pro in JSON
jamfProNotifications=$(curl -s -H "Authorization: Bearer ${apiToken}" -H "Accept: application/json" \
	"${jamfProURL}/api/v1/notifications" -X GET)

# Get total number of notifications
notificationCount=$(echo "$jamfProNotifications" | jq length)

# Iterate through notification details
while [[ "$index" -lt "$notificationCount" ]]; do

    # Get type of notification
    notificationType=$(echo "$jamfProNotifications" | jq -r ".[$index].type")

    # Verify notification is on approved alert list
	if grep -v '^#' "$selectedNotificationsFile" | grep -qw "$notificationType"; then

        # Get additional details on each notification (if available) and build out message
        notificationParamName=$(echo "$jamfProNotifications" | jq -r ".[$index].params.name | select(.!=null)")
        notificationParamDays=$(echo "$jamfProNotifications" | jq -r ".[$index].params.days | select(.!=null)")
		notificationString="<${jamfProURL}|${jamfProDomain}>: $notificationType"

        [[ -n "$notificationParamName" ]] && notificationString+=" for \`$notificationParamName\`"
        [[ -n "$notificationParamDays" ]] && notificationString+=" in $notificationParamDays days"

		notificationStrings+=("$notificationString")
    fi
    ((index++))
done

# If there are any notifications, print to console and post them to Slack
if [[ "${#notificationStrings[@]}" -gt "0" ]]; then
	notificationStringsDelimited=$(printf '%s\n' "${notificationStrings[@]}")
	slackPayload="payload={\"text\":\"$notificationStringsDelimited\"}"

	echo "${notificationStringsDelimited[*]}"

	output=$(curl -s -d "${slackPayload}" "$slackWebhook")
	result="$?"

	if [[ "$result" != "0" ]]; then
		echo "Error sending Slack notification; detailed error below."
		echo "$output"
	fi

	exit "$result"
else
	echo "No Jamf Pro Notifications."
fi

exit 0