import psutil
import urllib2
import datetime

def killproc(procname):
    for proc in psutil.process_iter():
        # check whether the process name matches
        if procname in proc.name():            
            print(str(datetime.datetime.now())+" restarted")
            proc.kill()

def running(url, check):
    req = urllib2.Request(url, "")
    response = urllib2.urlopen(req)
    result = response.read()
    return result==check

url = "http://172.16.64.9:8888/egglab?fn=ping"
check = """["hello"]"""

if not running(url,check):
    killproc("dazzle-server")


