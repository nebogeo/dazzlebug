#!/usr/bin/env python
# Red King Simulation Sonification
# Copyright (C) 2016 Foam Kernow
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

import os
import math
import time
import random
import sqlite3

import datetime
from binascii import a2b_base64
from PIL import Image

db = sqlite3.connect("seeme.db")
            
def save_imgdata(data,filename):
    #print(data[22:])
    fd = open(filename, 'wb')
    fd.write(a2b_base64(data[22:]))
    fd.close()

def get_filename(id):
    c = db.cursor()
    c.execute('select generation,replicate,population from egg where id=?', (id,))
    ret = c.fetchall()
    return str(id)+"-"+str(ret[0][0])+"-"+str(ret[0][1])+"-"+str(ret[0][2])+".png"

def get_pattern(id):
    c = db.cursor()
    c.execute('select data from render where pattern_id=?', (id,))
    return c.fetchall()
    
for id in range(1,9999999):
    fn = get_filename(id)
    t = get_pattern(id)
    if len(t)>0:
        print(fn)
        save_imgdata(t[0][0],"bugs/"+fn)

#save_imgdata()
    


