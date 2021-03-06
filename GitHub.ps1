Add-Type -Assembly System.ServiceModel.Web,System.Runtime.Serialization
$linkRegex = [regex]'\<(?<uri>.*?)\>\;\s*rel\s*=\s*"?(?<rel>(next|last))"?\s*'

function execute-jsonrequest([string]$uri, $method="GET", $body=$null) {
 $request = [System.Net.WebRequest]::Create($uri);
 $request.Method = $method;
 $credentials = new-object System.Net.NetworkCredential
 if ($global:GitHubUsername) {
     $headerValue = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("$global:GitHubUsername`:$global:GitHubPassword"));
     $request.Headers["Authorization"] = $headerValue
 }
 if ($body) {
   $request.ContentType = "application/json";
   $requestBody = [System.Text.Encoding]::UTF8.GetBytes($body);
   $request.ContentLength = $requestBody.Length;
   $requestStream = $request.GetRequestStream();
   
   $requestStream.Write($requestBody,0,$requestBody.Length);
   $requestStream.Close();
 }
 trap [System.Net.WebException] {
   $script:response = $_.Exception.Response;
   continue;
 }
 $response = $request.GetResponse();
 if (-not $response) { return; }
 # Read headers for limits
 if ($rateLimit = $response.Headers["X-RateLimit-Limit"]) {
   $global:GitHubLimit = [int]$rateLimit;
 }
 
 if ($rateRemaining = $response.Headers["X-RateLimit-Remaining"]) {
   $global:GitHubLimitRemaining = [int]$rateRemaining;
 }
 $responseStatus = [int]$response.StatusCode;
 if ($responseStatus -ge 400 -and $responseStatus -lt 600) {
   throw "GitHub responded with the error $responseStatus " + $response.StatusCode.ToString()
 }
 $responseStream = $response.GetResponseStream();
 $readStream = new-object System.IO.StreamReader $responseStream;
 $result = $readStream.ReadToEnd();
 
 $response.Close();
 
 $doc = (Convert-jsontoxml $result).root
 
 $returnValue = new-object psobject | add-member noteproperty root $doc -passthru
 
 if ($linkHeader = $response.Headers["Link"]) {
   $linkRegex.Matches($linkHeader).GetEnumerator() | % {
       add-member -inputobject $returnValue noteproperty $_.Groups["rel"].Value $_.Groups["uri"].Value
   }
 }
 return $returnValue
}
function Get-GitHubLimit { 
  if (-not $global:githubLimit) {
    execute-jsonrequest "https://api.github.com/users/$global:GitHubUsername" -method HEAD | out-null
  }
  write-host "GitHub calls: $global:GitHubLimitRemaining/$global:GitHubLimit"
}
function Convert-JsonToXml([string]$json)
{
    $bytes = [byte[]][char[]]$json
      $quotas = [System.Xml.XmlDictionaryReaderQuotas]::Max
      $jsonReader = [System.Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader($bytes,$quotas)
      try
      {
          $xml = new-object System.Xml.XmlDocument
   
          $xml.Load($jsonReader)
          $xml
      }
      finally
      {
          $jsonReader.Close()
      }
  }
function Get-GithubRepository {
 $text = (git remote show origin -n)
 $regex = new-object System.Text.RegularExpressions.Regex 'Fetch URL\: git\@github\.com:(?<username>[^\r\n\s]+)/(?<repo>[^\r\n\s]+)\.git', ignorecase
 $repoMatch = $regex.Match($text)
 if (-not $repoMatch.Success) { throw "could not find github uri" }
 $user = $repoMatch.Groups["username"].Value
 $repo = $repoMatch.Groups["repo"].Value;
 return new-object PSObject | add-member noteproperty -passthru "user" $user | add-member noteproperty -passthru "repo" $repo;
}
function Set-CurrentRemoteInfo([string]$uri, $currentRepository=$(Get-GithubRepository)) {
  return $uri.Replace(':user', $currentRepository.user).Replace(':repo', $currentRepository.repo);
}


function add-prop([string]$name, $val) {
  begin{
    if ($val -is [System.Xml.XmlElement]) { $val = $val.InnerText; }
  }
  process {
    $_ | add-member noteproperty $name $val
    return $_;
  }
}
function Get-GithubCache($currentRepository, $cacheName) {
  if (-not $global:githubCache) {
    $global:githubCache = @{}
  }
  $key = $currentRepository.user + $currentRepository.repo
  if (-not $global:githubCache.ContainsKey($key)) {
    $global:githubCache[$key] = @{}
  }
  if (-not $global:githubCache[$key].ContainsKey($cacheName)) {
    $global:githubCache[$key][$cacheName] = @{}
  }
  return $global:githubCache[$key][$cacheName];
}
function cache($cache, $keyProp) {
  process {
    if (-not $cache) { return $_; }
    $cacheKey = $_.$keyProp -as [string]
    $cache[$cacheKey] = $_;
    return $_;
  }
}
function get-cacheentry($cache, $key=$null, [bool]$nocache, [bool]$clearCache) {
   if ($clearCache) { Write-Host "Cache cleared"; $cache.Clear(); }
   if ($nocache) { return; }
   
   if ($key -ne $null -and $cache.ContainsKey([string]$key)) {
     Write-Host "Serving cached data"
     return $cache[[string]$key]
   } elseif (-not $key -and $cache.Count -gt 0) {
     Write-Host "Serving cached data"
     return $cache.Values;
   }
}
function Get-GitHubMilestone($name=$null, [switch]$nocache, [switch]$clearCache) {
 $current = Get-GithubRepository
 $cache = get-githubcache $current "milestones";
 
 if($c = get-cacheentry -cache $cache -key $name -nocache $nocache.IsPresent -clearCache $clearCache.IsPresent) { return $c; }
 
 $milestone = execute-jsonrequest (Set-CurrentRemoteInfo 'https://api.github.com/repos/:user/:repo/milestones' $current)
 
 $milestone.root.Item | ? { $name -eq $null -or $_.title.InnerText -eq $name} | % {
   new-object psobject |
             add-prop number $_.number |
             add-prop title $_.title |
             cache $cache title
   
 }
}
function Execute-GitHubData([string]$uriTemplate, $current, $method, $body = $null) {
    $nextUri = (Set-CurrentRemoteInfo $uriTemplate $current)
    while ($nextUri) {
      $response = execute-jsonrequest $nextUri $method $body; 
      if ($response.root.Item.Count -gt 0) {
        $response.root.Item | % { 
          write-output $_;
        }
      } else {
        write-output $response.root;
      }
      $nextUri = $response.next;
    }
}
function Get-GitHubData([string]$uriTemplate, $current) {
  Execute-GithubData $uriTemplate $current "GET";
}
function Post-GitHubData([string]$uriTemplate, $current, $body) {
  Execute-GithubData $uriTemplate $current "POST" $body;
}
function Patch-GitHubData([string]$uriTemplate, $current, $body) {
  Execute-GithubData $uriTemplate $current "PATCH" $body;
}
function Convert-XmlToIssue($cache) {
  begin {
    function read-labels($node) {
      process {
        $_.Item | % {
          $_.name.InnerText;
        }
      }
    }
  }
  process {
    % {
      new-object psobject -property @{
          type     = "issue";
          number   = [int]$_.number.InnerText;
          title    = $_.title.InnerText;
          url      = $_.url.InnerText;
          html_url = $_.html_url.InnerText;
          labels   = ($_.labels | read-labels)
      } | cache $cache number
    }
    
  }
}
function Get-GitHubIssue($spec="*", [switch]$nocache, [switch]$clearCache) {
  $current = Get-GitHubRepository;
  $cache = get-githubcache $current "issues";
  
  if($spec -is [int]) {
    $c = get-cacheentry -cache $cache -key $spec -nocache $nocache.IsPresent -clearCache $clearCache.IsPresent;
    if ($c) { return $c; }
  }
 
  if ($spec -isnot [int] -and $spec -notcontains "*" -and $spec -notcontains "?") { $spec = "*$spec*" }
  $href = $(if ($spec -isnot [int]) {'https://api.github.com/repos/:user/:repo/issues'} else { "https://api.github.com/repos/:user/:repo/issues/$spec" })
  Get-GithubData $href $current |
    Convert-XmlToIssue $cache |
    ?{ ($spec -is [int] -and $_.number -eq $spec) -or $_.title -like $spec}
  
}
function Convert-IssueToJson([string]$title, [string]$body, [string]$milestone, [string[]]$labels, [string]$assignee=$global:GitHubUsername) {
  
  $content = @();
  if ($milestone) {
    $number = (get-githubmilestone $milestone).number
    if (-not $number) { throw "Milestone $milestone not found" }
    
    $content += "`"milestone`": $number";
  }
  if ($labels) {
    $content += '"labels": [ "' + [string]::Join("`",`"", $labels) + '"]';
  }
  if ($title) {
    $content += "`"title`": `"$title`"";
  } 
  if ($body) {
    $content += "`"body`": `"$body`""
  }
  if ($assignee) {
    $content += "`"assignee`": `"$assignee`"";
  }
  return "{`r`n  " + [string]::Join(",`r`n  ", $content) + "`r`n}";
}
function Set-GitHubIssue([string]$title, [string]$body, [string]$milestone, [string[]]$labels, [string]$assignee=$global:GitHubUsername) {
  begin {
    $current = Get-GitHubRepository;
  }
  process {
    % {
      if ($_.type -eq "issue") {
        $uri = $_.url;
        $finalLabels = new-object System.Collections.ArrayList;
        $_.labels | % { $finalLabels.Add($_) };
        
        $labels | % {
          if ($_.StartsWith("+")) {
            if (-not $finalLabels.Contains(($name = $_.Substring(1)))) {
              $finalLabels.Add($name);
            }
          } elseif ($_.StartsWith("-")) {
            $finalLabels.Remove($_.Substring(1));
          } else { 
            $finalLabels = $labels; break;
          }
        }
        $content =  (convert-issuetojson $title $body $milestone $finalLabels $assignee);
        Patch-GitHubData $uri $current $content | Convert-XmlToIssue
      }
    }
  }
}
function Create-GitHubIssue([string]$title, [string]$body, [string]$milestone, [string[]]$labels, [string]$assignee=$global:GitHubUsername) {
  $current = Get-GitHubRepository;
  
  Post-GithubData 'https://api.github.com/repos/:user/:repo/issues' $current (convert-issuetojson $title $body $milestone $labels $assignee) |
    Convert-XmlToIssue
  
}