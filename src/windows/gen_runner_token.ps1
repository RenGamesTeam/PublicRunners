param (
    [string]$token,
    [string]$owner
)

# 定义 API URL
$apiUrl = "https://api.github.com/orgs/$owner/actions/runners/registration-token"

# 设置 HTTP 请求头
$headers = @{
    "Accept" = "application/vnd.github+json"
    "Authorization" = "Bearer $token"
    "X-GitHub-Api-Version" = "2022-11-28"
}

# 发送 POST 请求并获取响应
$response = Invoke-RestMethod -Uri $apiUrl -Method Post -Headers $headers

# 提取 token 并输出
$registration_token = $response.token
Write-Output $registration_token
