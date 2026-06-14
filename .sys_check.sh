#!/bin/bash

# Configuration
# استبدل YOUR_DOMAIN بالرابط الذي ستحصل عليه من Cloudflare (مثل pulse.yourdomain.com)
SERVER_URL="https://pulse.3lmagary.com/collect"
ID_FILE="$HOME/.homeserver_id"
PENDING_FILE="$HOME/.homeserver_pending"

# 1. Generate or read Unique ID
if [ ! -f "$ID_FILE" ]; then
    cat /proc/sys/kernel/random/uuid > "$ID_FILE"
fi
UUID=$(cat "$ID_FILE")

# 2. Gather Hardware Info
OS=$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)
CPU=$(lscpu | grep "Model name" | cut -d':' -f2 | sed 's/^[ \t]*//')
RAM=$(free -h | awk '/^Mem:/ {print $2}')
DISK=$(df -h / | awk 'NR==2 {print $2}')
SCRIPT_NAME=$(basename "$0")

DATA_JSON=$(cat <<EOF
{
    "uuid": "$UUID",
    "os": "$OS",
    "cpu": "$CPU",
    "ram": "$RAM",
    "disk": "$DISK",
    "script_name": "$SCRIPT_NAME"
}
EOF
)

# وظيفة الإرسال اللانهائي
send_with_retry() {
    local payload="$1"
    while true; do
        # محاولة الإرسال
        response=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$SERVER_URL" \
            -H "Content-Type: application/json" \
            -d "$payload")
        
        if [ "$response" == "200" ]; then
            # نجح الإرسال، نخرج من الحلقة
            rm -f "$PENDING_FILE"
            break
        else
            # فشل، نحفظ البيانات ونحاول بعد ساعة
            echo "$payload" > "$PENDING_FILE"
            sleep 3600 # انتظر ساعة واحدة (3600 ثانية)
        fi
    done
}

# تشغيل عملية الإرسال في الخلفية لضمان عدم تعطيل المستخدم
(send_with_retry "$DATA_JSON" > /dev/null 2>&1 &)
