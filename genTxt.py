#! /usr/bin/env python

import json
import requests
import hashlib
import base64
import os
import getpass
from PIL import Image, UnidentifiedImageError

IRURLBASE = 'https://members-ng.iracing.com'
REPODIR = os.path.dirname(__file__)

def getTracks(cookies, paths):
  trackpath = paths['track']['get']['link']
  s3path = requests.get(trackpath, cookies=cookies).json()['link']
  return requests.get(s3path).json()

def formatTracks(trackJson):
  trackList = list()
  for track in trackJson:
    if track.get('config_name', False):
      trackList.append(f"{track['track_id']} {track['track_name']} - {track['config_name']}")
    else:
      trackList.append(f"{track['track_id']} {track['track_name']}")
  with open(f'{REPODIR}/tracks.txt', 'w') as tf:
    tf.write('\n'.join(trackList))
  return trackList

def getSeries(cookies, paths):
  seriespath = paths['series']['stats_series']['link']
  s3path = requests.get(seriespath, cookies=cookies).json()['link']
  return requests.get(s3path).json()

def getLicense(allowedLicense):
  licenses = ['R', 'D', 'C', 'B', 'A', 'Pro', 'Pro/WC']
  if len(allowedLicense) > 1:
    return licenses[allowedLicense[1]['license_group']]
  else:
    return licenses[allowedLicense[0]['license_group']]

def formatSeries(seriesJson):
  seriesList = list()
  licenses = ['R', 'D', 'C', 'B', 'A', 'Pro', 'Pro/WC']
  for series in seriesJson:
    if not series['series_name'].startswith('13th Week'):
      for season in series['seasons']:
        seriesList.append('\n'.join(
          [f"{season['season_id']} {series['series_name']} : {series['category']}",
           f"\tLICENSE {licenses[(season['license_group']) - 1]}",
           f"\tID {season['series_id']}"]
        ))
    if series['logo']:
      seriesLogo = f"https://images-static.iracing.com/img/logos/series/{series['logo']}"
      logoData = requests.get(seriesLogo)
      with open(f"{REPODIR}/html/images/{series['series_id']}.png", 'wb') as logo:
        logo.write(logoData.content)
      try:
        with Image.open(f"{REPODIR}/html/images/{series['series_id']}.png") as logo:
          icon = logo.resize((57, 22))
          icon.save(f"{REPODIR}/html/images/icon/{series['series_id']}.png")
      except UnidentifiedImageError:
        print(f"==> Series {series['series_name']} (id {series['series_id']}) doesn't havea valid image.")
  with open(f"{REPODIR}/series.txt", 'w') as st:
    st.write('\n'.join(seriesList))
  return seriesList


def irLogin(user, pw):
  encodedpw = base64.b64encode(
    hashlib.sha256(bytes(pw, 'utf-8') + bytes(user.lower(), 'utf-8')).digest()
    )
  logindata = {
    'email': user,
    'password': encodedpw.decode('utf-8')
  }
  auth = requests.post(f'https://members-ng.iracing.com/auth', data=logindata)
  cookies = auth.cookies
  r = requests.get(f'{IRURLBASE}/data/doc', cookies=cookies)
  return cookies, json.loads(r.text)

def main():
  email = input("iRacing email: ")
  password = getpass.getpass("iRacing password: ")
  cookies, paths = irLogin(email, password)
  allTracks = getTracks(cookies, paths)
  formatTracks(allTracks)
  allSeries = getSeries(cookies, paths)
  formatSeries(allSeries)

if __name__ == '__main__':
  main()
