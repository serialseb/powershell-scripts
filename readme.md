# My personal and maybe useful powershell scripts

To install, go to the folder where you have your powershell home and do
    git clone http://github.com/serialseb/powershell-scripts inc

Then edit your profile (a simple `notepad $profile` should be sufficient), and add

    ls (join-path ([system.io.path]::getdirectoryname($profile)) "inc") -fi *.ps1 | ?{ $_.fullname -ne $profile } | select -unique | %{ . $_.fullname; write-host "Imported $_" }