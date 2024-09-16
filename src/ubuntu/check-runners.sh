#!/bin/bash

# 定义计时器的时间长度 (秒)
TIMER_DURATION=$1  # 10分钟
OS=$2
INTERVAL=60  # 每隔60秒进行检查
ORG_NAME="RenGamesTeam"  # 组织名称

# 定义GitHub API请求的URL
API_URL="https://api.github.com/orgs/$ORG_NAME/actions/runners"

# 等待120秒(等待Runner运行)
echo "Waiting for 120 seconds before starting the timer..."
sleep 120

# 退出标识符
exit_flag=false

# 计时器循环
while [ $TIMER_DURATION -gt 0 ]; do
    echo "Remaining time: $((TIMER_DURATION / 60)) minutes and $((TIMER_DURATION % 60)) seconds"

    # 使用curl获取组织中所有的self-hosted runners，并解析其状态
    echo "Fetching self-hosted Linux runners from $ORG_NAME organization..."

    RESPONSE=$(curl -L -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "$API_URL" | jq -c ".runners[] | select(.labels[].name == \"$OS\")")

    if [ -z "$RESPONSE" ]; then
      echo "No Linux runners found, exit..."
      exit 0
    else
      # 遍历每个Linux runner并检查状态
      echo "$RESPONSE" | while read runner; do
          RUNNER_NAME=$(echo "$runner" | jq -r '.name')
          RUNNER_STATUS=$(echo "$runner" | jq -r '.status')

          echo "Runner: $RUNNER_NAME, Status: $RUNNER_STATUS"

          if [ "$RUNNER_STATUS" != "online" ]; then
              echo "Runner $RUNNER_NAME not running, exit..."
              exit_flag=true  # 设置退出标识符为true
              break  # 结束while循环
          fi
      done
    fi

    # 如果退出标识符为true，退出整个脚本
    if [ "$exit_flag" = true ]; then
        exit 0
    fi

    # 等待60秒后再次进行检查
    sleep $INTERVAL
    TIMER_DURATION=$((TIMER_DURATION - $INTERVAL))
done

echo "Timer completed without any non-idle runners."
