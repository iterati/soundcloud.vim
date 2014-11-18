import subprocess


proc = subprocess.Popen([
    "/Applications/VLC.app/Contents/MacOS/VLC",
    "--quiet", "--intf", "http", "--http-password", "silverlining",
], stdout=subprocess.PIPE, stdin=subprocess.PIPE, stderr=subprocess.PIPE, shell=False)
proc.wait()
