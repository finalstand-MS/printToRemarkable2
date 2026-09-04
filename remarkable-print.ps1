$path="C:\reMarkable\print.prn"
$upload="http://10.11.99.1/upload"

while($true){
    if((Test-Path $path) -and ((Get-Item $path).Length -gt 0)){
        try{
            curl.exe -s -F "file=@$path" $upload
            Remove-Item $path -Force
        } catch {}
    }
    Start-Sleep -Milliseconds 500
}
