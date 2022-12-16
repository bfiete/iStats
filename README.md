# iStats
iRacing stats

This tool generates statistics from iRacing participation data. The programming language used for HTML generation is [BeefLang](https://www.beeflang.org/).

# Modifying Series.txt

You can manually extract iRacing series data by viewing the source from https://members.iracing.com/membersite/member/Series.do - a series ID, for example, will be in some JSON around `"seriesid":` for each series.

Also you need to generate correctly-sized series logo files for `html/images/` and `html/images/icon`. The images you want are the ones displayed when you click the `+` button to open up a series from the `Series.do` page. The source URL will be something like: https://ir-core-sites.iracing.com/members/member_images/series/seriesid_315/logo.jpg