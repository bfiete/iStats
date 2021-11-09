#pragma warning disable 168
using System;
using CURL;
using Beefy.utils;
using System.IO;
using System.Diagnostics;
using System.Collections;
using System.Text;

namespace iStats
{
	enum SeriesKind
	{
		Unknown = -1,
		Road,
		Oval,
		DirtRoad,
		DirtOval,
	}

	struct CarEntry
	{
		public int32 mIR;
		public float mAvgLapTime;
		public float mFastestLapTime;
	}

	class CarClassEntry
	{
		public Dictionary<String, List<CarEntry>> mCarDict = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
	}

	class RacingSubSession
	{
		public int32 mId;
		public Dictionary<String, CarClassEntry> mCarClassDict = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		public int32 mHighestIR;
	}

	class RacingSession
	{
		public DateTime mSessionDate;
		public List<RacingSubSession> mSubSessions = new .() ~ DeleteContainerAndItems!(_);
	}

	class RacingDay
	{
		public Dictionary<int, RacingSession> mSessions = new .() ~ DeleteDictionaryAndValues!(_);
	}

	class RacingWeek
	{
		public RacingSeries mSeries;
		public int32 mSeasonId;
		public int32 mSeasonYear;
		public int32 mSeasonNum; // 0 - based
		public int32 mWeekNum; // 0 - based
		public int32 mTrackId = -1;
		public List<RacingDay> mRacingDays = new .() ~ DeleteContainerAndItems!(_);
		public int32 mSplitMax;
		public int32 mFieldMax;
		public int32 mSplitPeak;
		public int32 mFieldPeak;
		public bool mIsDup;

		public int32 TotalWeekIdx
		{
			get
			{
				return mSeasonYear * 52 + mSeasonNum * 13 + mWeekNum;
			}
		}
	}

	enum RacingLicense
	{
		Unknown = -1,
		R,
		D,
		C,
		B,
		A
	}

	class RacingSeries
	{
		public SeriesKind mKind = .Unknown;
		public String mName = new .() ~ delete _;
		public String mSafeName = new .() ~ delete _;
		public String mRemapName ~ delete _;
		public String mID ~ delete _;
		public RacingLicense mLicense = .Unknown;
		public int32 mCurrentSeasonId;
		public int32 mCurrentSeasonWeek = -1;
		public List<RacingWeek> mWeeks = new .() ~ DeleteContainerAndItems!(_);
		public List<RacingWeek> mDupWeeks = new .() ~ DeleteContainerAndItems!(_);

		public String SafeName
		{
			get
			{
				if (mSafeName.IsEmpty)
				{
					mSafeName.Set(mName);
					for (var c in ref mSafeName.RawChars)
					{
						if ((c == ' ') || (c == '-') || (c == '.'))
							c = '_';
					}
				}
				return mSafeName;
			}
		}
	}

	enum CacheMode
	{
		AlwaysUseCache,
		RefreshCurrentSeason,
		ScanForNewSeasonIds
	}

	class CacheEntry
	{
		public String mKey;
		public String mData ~ delete _;
		public int32 mDBBucketIdx = -1;
		public bool mDirty;
		public Stream mDBStream;
		public int64 mDBStreamPos;

		public void Get(String data)
		{
			if (mData != null)
			{
				data.Set(mData);
				return;
			}
			mDBStream.Position = mDBStreamPos;
			mDBStream.ReadStrSized32(data);
		}

		public void MakeEmpty()
		{
			if (mData != null)
			{
				mData.Clear();
				return;
			}
			mData = new .();
			mDBStream = null;
			mDBStreamPos = 0;
		}
	}

	class CacheBucket
	{
		public List<CacheEntry> mEntries = new .() ~ delete _;
		public bool mDirty;
	}

	class Program
	{
		const int32 cCacheMagic = 0x4BF8512A;
		Dictionary<String, RacingSeries> mSeriesDict = new .() ~ DeleteDictionaryAndValues!(_);
		Dictionary<int, String> mTrackNames = new .() ~ DeleteDictionaryAndValues!(_);
		Dictionary<int, int> mCurrentSeriesIdWeek = new .() ~ delete _;
		Dictionary<String, CacheEntry> mCache = new .() ~ DeleteDictionaryAndKeysAndValues!(_);
		int32 mCurDBBucketIdx;
		int32 mCurDBBucketCount;
		List<Stream> mDBStreams = new .() ~ DeleteContainerAndItems!(_);

		CacheMode mCacheMode = .RefreshCurrentSeason;//.RefreshCurrentSeason;//.AlwaysUseCache;
		String mUserName = new .() ~ delete _;
		String mPassword = new .() ~ delete _;

		CURL.Easy mCurl = new .() ~ delete _;
		bool mLoggedIn = false;

		int mStatsGetCount = 0;
		int mStatsTransferCount = 0;
		int mLowestSeasonId = 2626; // From Jan 2020
		int mHighestSeasonId = 0;
		HashSet<int32> mRetrievedCurrentSeasonIdSet = new .() ~ delete _;

		void WriteCache(bool forceWrite = false)
		{
			List<CacheEntry> unbucketedCacheEntries = scope .();

			for (var cacheEntry in mCache.Values)
			{
				// Pick up any unassigned cache entries
				if (cacheEntry.mDBBucketIdx == -1)
				{
					unbucketedCacheEntries.Add(cacheEntry);
					//ReferenceCache(cacheEntry);
				}
			}

			unbucketedCacheEntries.Sort(scope (lhs, rhs) => lhs.mKey <=> rhs.mKey);

			for (var cacheEntry in unbucketedCacheEntries)
			{
				cacheEntry.mDirty = true;
				cacheEntry.mDBBucketIdx = mCurDBBucketIdx;
				mCurDBBucketCount++;
				if (mCurDBBucketCount > 2048)
				{
					mCurDBBucketIdx++;
					mCurDBBucketCount = 0;
				}
			}

			//
			/*
			cacheEntry.mDirty = true;
			cacheEntry.mDBBucketIdx = mCurDBBucketIdx;
			mCurDBBucketCount++;

			if (mCurDBBucketCount > 2048)
			{
				mCurDBBucketIdx++;
				mCurDBBucketCount = 0;
			}
			*/

			List<CacheBucket> cacheBuckets = scope .();
			defer ClearAndDeleteItems(cacheBuckets);

			for (int cacheBucketIdx < mCurDBBucketIdx + 1)
				cacheBuckets.Add(new .());
			
			for (var cacheEntry in mCache.Values)
			{
				var cacheBucket = cacheBuckets[cacheEntry.mDBBucketIdx];
				cacheBucket.mEntries.Add(cacheEntry);
				if ((cacheEntry.mDirty) || (forceWrite))
					cacheBucket.mDirty = true;
			}

			int bucketsDity = 0;
			for (var cacheBucket in cacheBuckets)
			{
				if (!cacheBucket.mDirty)
					continue;

				Stream streamToClose = null;
				for (var cacheEntry in cacheBucket.mEntries)
				{
					if (cacheEntry.mData == null)
					{
						cacheEntry.mData = new .();
						cacheEntry.mDBStream.Position = cacheEntry.mDBStreamPos;
						cacheEntry.mDBStream.ReadStrSized32(cacheEntry.mData);
						streamToClose = cacheEntry.mDBStream;
						cacheEntry.mDBStream = null;
					}
				}

				if (streamToClose != null)
				{
					bool wasRemoved = mDBStreams.Remove(streamToClose);
					Debug.Assert(wasRemoved);
					delete streamToClose;
				}

				bucketsDity++;
				FileStream fs = new .();
				fs.Create(scope $"db/db{@cacheBucket.Index:000000}.dat");
				fs.Write(cCacheMagic);
				for (var cacheEntry in cacheBucket.mEntries)
				{
					fs.WriteStrSized32(cacheEntry.mKey);
					//cacheEntry.mDBStream = fs;
					//cacheEntry.mDBStreamPos = fs.Position;

					cacheEntry.mDBStream = null;
					cacheEntry.mDBStreamPos = -2;

					fs.WriteStrSized32(cacheEntry.mData);
					DeleteAndNullify!(cacheEntry.mData);
				}
				fs.Write((int32)0);
				fs.Write((int32)0);

				//mDBStreams.Add(fs);
				delete fs;
			}

			Console.WriteLine($"{bucketsDity} db buckets written");

			/*FileStream fs = scope .();
			fs.Create("Cache.dat");
			fs.Write(cCacheMagic);
			for (var kv in mCache)
			{
				fs.WriteStrSized32(kv.key);
				fs.WriteStrSized32(kv.value);
			}*/
		}

		void ReadConfig()
		{
			StructuredData sd = scope .();
			sd.Load("Config.toml");

			sd.Get("UserName", mUserName);
			sd.Get("Password", mPassword);
		}

		void TestSanity(StringView areaName)
		{
			HashSet<Stream> set = scope .();
			for (var entry in mDBStreams)
			{
				if (!set.Add(entry))
					Runtime.FatalError(scope $"TestSanity failed at {areaName} on {entry}");
			}
		}

		void ReadCache()
		{
			/*FileStream fs = scope .();
			if (fs.Open("Cache.dat") case .Err)
				return;

			int cacheMagic = fs.Read<int32>().Value;
			Runtime.Assert(cacheMagic == cCacheMagic);
				
			while (true)
			{
				String key = new .();
				if (fs.ReadStrSized32(key) case .Err)
				{
					delete key;
					break;
				}
				CacheEntry cacheEntry = new .();
				cacheEntry.mData = new .();

				
				fs.ReadStrSized32(cacheEntry.mData);
				mCache[key] = cacheEntry;
			}*/

			Console.Write("Loading cache ");

			int truncEntries = 0;

			for (int32 bucketIdx = 0; true; bucketIdx++)
			{
				FileStream fs = new .();
				if (fs.Open(scope $"db/db{bucketIdx:000000}.dat") case .Err)
				{
					delete fs;
					break;
				}

				mDBStreams.Add(fs);

				int cacheMagic = fs.Read<int32>().Value;
				Runtime.Assert(cacheMagic == cCacheMagic);

				mCurDBBucketIdx = bucketIdx;
				mCurDBBucketCount = 0;

				while (true)
				{
					String key = new .();
					if (fs.ReadStrSized32(key) case .Err)
					{
						delete key;
						break;
					}

					if (key.IsEmpty)
					{
						delete key;
						break;
					}

					bool useStreamPtr = true;

					CacheEntry cacheEntry = new .();
					cacheEntry.mKey = key;
					cacheEntry.mDBBucketIdx = bucketIdx;

					if (useStreamPtr)
					{
						cacheEntry.mDBStream = fs;
						cacheEntry.mDBStreamPos = fs.Position;

						int pos = fs.Position;

						int32 len = fs.Read<int32>();
						fs.Seek(len, .Relative);

						if (fs.Position != pos + len + 4)
						{
							truncEntries++;
							delete key;
							delete cacheEntry;
							break;
						}
					}
					else
					{
						cacheEntry.mData = new .();
						fs.ReadStrSized32(cacheEntry.mData);
					}
					mCache[key] = cacheEntry;
					mCurDBBucketCount++;
				}

				if (bucketIdx % 20 == 0)
				{
					Console.Write(".");
				}
			}

			Console.WriteLine($". {truncEntries} truncated entries.");

			TestSanity("ReadCache");
		}

		void MakeUTF8(String str)
		{
			bool isAsciiEX = false;
			for (char8 c in str.RawChars)
			{
				if (c >= '\x80')
				{
					if ((str[Math.Max(0, @c.Index - 1)] < '\x80') &&
						(str[Math.Min(@c.Index + 1, str.Length - 1)] < '\x80'))
						isAsciiEX = true;
				}
			}

			if (!isAsciiEX)
				return;

			String newStr = scope .();

			int newSubsessionPrevIdx = 0;

			// Sanitize - not UTF8
			for (var c in ref str.RawChars)
			{
				if (c >= '\x80')
				{
					int appendLen = @c.Index - newSubsessionPrevIdx;
					if (appendLen > 0)
					{
						newStr.Append(str.Substring(newSubsessionPrevIdx, appendLen));
						newSubsessionPrevIdx = @c.Index + 1;
					}
					newStr.Append((char32)c);
				}
			}

			if (newStr.Length > 0)
			{
				int appendLen = str.Length - newSubsessionPrevIdx;
				if (appendLen > 0)
					newStr.Append(str.Substring(newSubsessionPrevIdx, appendLen));
				//str = newStr;

				str.Set(newStr);
			}
		}

		public Result<void> Get(StringView url, String result, bool allowCache = true)
		{
			mStatsGetCount++;

			if (allowCache)
			{
				if (mCache.TryGetAlt(url, var cacheKey, var cacheEntry))
				{
					if (cacheEntry.mData != null)
					{
						result.Append(cacheEntry.mData);
						MakeUTF8(result);
					}
					else
					{
						cacheEntry.mDBStream.Position = cacheEntry.mDBStreamPos;
						cacheEntry.mDBStream.ReadStrSized32(result);
						MakeUTF8(result);
					}
					
					return .Ok;
				}
			}

			void SetCache()
			{
				if (mCache.TryAddAlt(url, var keyPtr, var valuePtr))
				{
					*keyPtr = new String(url);
					CacheEntry cacheEntry = new CacheEntry();
					cacheEntry.mKey = *keyPtr;
					cacheEntry.mData = new String(result);
					*valuePtr = cacheEntry;
				}
				else
				{
					CacheEntry cacheEntry = *valuePtr;
					
					if (cacheEntry.mData == null)
					{
						String prevData = scope .();
						cacheEntry.mDBStream.Position = cacheEntry.mDBStreamPos;
						cacheEntry.mDBStream.ReadStrSized32(prevData);
						if (prevData == result)
							return;
						cacheEntry.MakeEmpty();
					}
					else
					{
						if (cacheEntry.mData == result)
							return;
					}
					cacheEntry.mData.Set(result);
					cacheEntry.mDirty = true;
				}
			}

			String cleanString = scope .();
			for (var c in url.RawChars)
			{
				if ((c == '/') || (c == '?') || (c == '&') || (c == '.') || (c == ':') || (c == '='))
					c = '_';
				cleanString.Append(c);
			}

			if (cleanString.StartsWith("https___members_iracing_com_"))
				cleanString.Remove(0, "https___members_iracing_com_".Length);

			String cacheFilePath = scope $"cache/{cleanString}.txt";
			if ((allowCache) && (File.ReadAllText(cacheFilePath, result) case .Ok))
			{
				MakeUTF8(result);
				SetCache();
				return .Ok;
			}

			if (!mLoggedIn)
			{
				Login();
				mLoggedIn = true;
			}

			mStatsTransferCount++;
			Transfer trans = scope .(mCurl);
			trans.Init(url);
			let httpResult = trans.Perform();
			switch (httpResult)
			{
			case .Ok(let val):
				StringView sv = .((.)val.Ptr, val.Length);
				result.Append(sv);
				//File.WriteAllText(cacheFilePath, sv);
				//String contentType = trans.GetContentType(.. scope .());
				MakeUTF8(result);
				SetCache();
				return .Ok;
			default:
				return .Err;
			}
		}

		public void Login()
		{
			Transfer trans = scope .(mCurl);
			mCurl.SetOpt(.CookieFile, "cookies.txt");
			trans.InitPost("https://members.iracing.com/membersite/Login", scope $"username={mUserName}&password={mPassword}");
			let result = trans.Perform();
			switch (result)
			{
			case .Ok(let val):
				StringView sv = .((.)val.Ptr, val.Length);
				int z = 123;
			default:
			}
		}

		void ParseCSV(StringView str, List<StringView> outStrings)
		{
			int quoteStart = -1;
			for (var c in str.RawChars)
			{
				if (c == '"')
				{
					if (quoteStart == -1)
						quoteStart = @c.Index;
					else
					{
						outStrings.Add(str.Substring(quoteStart + 1, @c.Index - quoteStart - 1));
						quoteStart = -1;
					}
				}
			}
		}

		void RetrieveSeriesDo()
		{
			Console.Write("Retrieving Series.do");

			var doInfo = scope String ();
			Get("https://members.iracing.com/membersite/member/Series.do", doInfo, false);

			int32 highestYear = 0;

			var findStr = "var YearAndQuarterListing = extractJSON('";
			int findIdx = doInfo.IndexOf(findStr);
			if (findIdx != -1)
			{
				int idx = findIdx + findStr.Length;
				int endIdx = doInfo.IndexOf('\'', idx);
				if (endIdx != -1)
				{
					StringView foundStr = doInfo.Substring(idx, endIdx - idx);

					StructuredData sd = scope .();
					sd.LoadFromString(foundStr);

					for (var result in sd.Enumerate())
					{
						int32 year = sd.GetInt("year");
						if (year >= highestYear)
							highestYear = year;

						for (sd.Enumerate("quarters"))
						{
							if (year == highestYear)
								mRetrievedCurrentSeasonIdSet.Clear();
							for (sd.Enumerate("seasons"))
							{
								int32 seasonId = sd.GetCurInt();
								if (year == highestYear)
									mRetrievedCurrentSeasonIdSet.Add(seasonId);
								mHighestSeasonId = Math.Max(mHighestSeasonId, seasonId);
							}
						}
					}
				}
			}
			Console.WriteLine();
			Console.Write($"Retrieved Season Ids:");
			List<int32> seasonIds = scope .(mRetrievedCurrentSeasonIdSet.GetEnumerator());
			seasonIds.Sort();
			for (var id in seasonIds)
				Console.Write($" {id}");
			Console.WriteLine();
		}

		void Retrieve()
		{
			int highSeriesId = 0;
			for (var seriesId in mCurrentSeriesIdWeek.Keys)
				highSeriesId = Math.Max(highSeriesId, seriesId);

			bool breakNow = false;
			for (int32 seasonId in (mLowestSeasonId...mHighestSeasonId).Reversed) // From Jan 2020
			{
				if (breakNow)
					break;

				int32 seasonYear = -1;
				int32 seasonNum = -1;

				StringView seriesName;

				WeekLoop: for (int32 week in 0...12)
				{
					RacingWeek racingWeek = null;

					bool hadResults = false;

					// TODO: Allow a "discovery" phase when we move to the new season

					bool allowCache = true;
					if (mCacheMode != .AlwaysUseCache)
					{
						if (mCurrentSeriesIdWeek.TryGetValue(seasonId, var currentSeriesWeek))
						{
							if (week >= currentSeriesWeek)
								allowCache = false;
						}
						else
						{
							if (mRetrievedCurrentSeasonIdSet.Contains(seasonId))
							{
								allowCache = false;
							}
						}
					}

					if ((mCacheMode == .ScanForNewSeasonIds) && (seasonId > highSeriesId))
					{
						// This ID may have been allocated for a new series id
						allowCache = false;
					}

					int prevTransferCount = mStatsTransferCount;

					bool wroteSeries = false;
					Console.Write($"SeasonId: {seasonId} Week: {week+1}");
					if (!allowCache)
						Console.Write(" [NoCache]");

					String raceResults  = scope .();
					Get(scope $"https://members.iracing.com/memberstats/member/GetSeriesRaceResults?raceweek={week}&seasonid={seasonId}", raceResults, allowCache);

					StructuredData sd = scope .();
					sd.LoadFromString(raceResults);

					int prevSubSesssionId = -1;

					RaceLoop: for (var kv in sd.Enumerate("d"))
					{
						int64 startTime = sd.GetLong("1");
						int32 resulCarClassId = sd.GetInt("2");
						int32 trackId = sd.GetInt("3");
						int32 sessionId = sd.GetInt("4");
						int32 subSessionId = sd.GetInt("5");
						int32 officialSession = sd.GetInt("6");
						int32 sizeOfField = sd.GetInt("7");
						int32 resultStrengthOfField = sd.GetInt("8");

						DateTimeOffset offset = DateTimeOffset.FromUnixTimeMilliseconds(startTime);

						DateTime sessionDate = offset.DateTime;

						bool isCurrentSeason = false;

						var sessionAgeHours = (DateTime.UtcNow - sessionDate).TotalHours;
						if (sessionAgeHours < 24*7)
							isCurrentSeason = true;

						//dt = dt.ToLocalTime();
						
						/*if (officialSession != 1)
							continue;*/
						if (prevSubSesssionId == subSessionId)
							continue; // Repeat (multiclass)

						/*if (seasonId <= 3343)
						{
							NOP!();
						}*/

						if (week == 0)
						{
							//Console.WriteLine("Session {0:dd} {0:MMMM} {0:yyyy}, {0:hh}:{0:mm}:{0:ss} {0:tt} ", dt);

							float seasonNumF = sessionDate.DayOfYear / (7*13.0f);
							seasonYear = sessionDate.Year;
							seasonNum = (.)Math.Round(seasonNumF);
							if (seasonNum == 4)
							{
								seasonNum = 0;
								seasonYear++;
							}

							if (seasonYear == 2019)
								break WeekLoop;
						}

						RacingSeries series = null;
						RacingSession racingSession = null;
						RacingSubSession racingSubSession = null;

						String subsessionData = scope .();
						Get(scope $"https://members.iracing.com/membersite/member/GetEventResultsAsCSV?subsessionid={subSessionId}", subsessionData);

						for (var line in subsessionData.Split('\n'))
						{
							if (@line.Pos == 0)
								continue;

							List<StringView> elements = scope .();
							ParseCSV(line, elements);

							if (elements.Count < 35)
								continue;

							var finPos = int32.Parse(elements[0]).GetValueOrDefault();
							//1 carId
							var carName = elements[2];
							var carClassId = elements[3];
							var carClass = elements[4];
							//5 TeamId
							//6 custID
							var name = elements[7];
							//8 startPos
							//9 curNum
							//10 outId
							//11 out
							//12 interval
							//13 lapsLed
							//14 qualiTime
							var avgLapTime = elements[15];
							var fastestLapTime = elements[16];
							//17 fastLapNum
							//18 lapsComp
							//19 inc
							//20 pts
							//21 clubPts
							//22 div
							//23 clubID
							//24 club
							var oldIRating = int32.Parse(elements[25]).GetValueOrDefault();
							//26 newIRating
							//27 oldLicense
							//28 oldLicenseSub
							//29 newLicense
							//30 newLicenseSub
							seriesName = elements[31];
							//32 maxFuelFillPct
							//33 weightPenalty
							//34 aggPts

							seriesName.Trim();
							if ((seriesName.Contains("13th Week")) || (week+1 == 13))
							{
								// We don't track 13th week races, and these just clutter up our Series.txt
								Console.Write($" Skipping {seriesName} Week {week + 1}");
								break RaceLoop;
							}

							if (series == null)
							{
								//Console.WriteLine("{1:seriesName} {0:dd} {0:MMMM} {0:yyyy}, {0:hh}:{0:mm}:{0:ss} {0:tt} ", dt, seriesName);

								if (!wroteSeries)
								{
									Console.Write(" Season:{0} {1} @ {2:MMMM} {2:dd} {2:yyyy}", seasonNum + 1, seriesName, sessionDate);
									wroteSeries = true;
								}

								int remapItrCount  = 0;
								StringView useSeriesName = seriesName;
								while (true)
								{
									if (mSeriesDict.TryAddAlt(useSeriesName, var namePtr, var seriesPtr))
									{
										series = *seriesPtr = new .();
										series.mName.Set(useSeriesName);
										*namePtr = series.mName;
									}
									else
									{
										series = *seriesPtr;
									}

									if (series.mRemapName == null)
										break;
									useSeriesName = series.mRemapName;

									if (++remapItrCount >= 100)
									{
										Console.WriteLine($" ERROR: remap loop detected in {seriesName}");
										break;
									}
								}

								if ((isCurrentSeason) && (seasonId >= series.mCurrentSeasonId))
								{
									series.mCurrentSeasonId = seasonId;
									series.mCurrentSeasonWeek = week;
								}

								if (racingWeek == null)
								{
									racingWeek = new RacingWeek();
									racingWeek.mSeries = series;
									racingWeek.mSeasonId = seasonId;
									racingWeek.mWeekNum = week;
									racingWeek.mSeasonYear = seasonYear;
									racingWeek.mSeasonNum = seasonNum;
									if (series.mWeeks.FindIndex(scope (checkWeek) => checkWeek.TotalWeekIdx == racingWeek.TotalWeekIdx) != -1)
									{
										racingWeek.mIsDup = true;
										series.mDupWeeks.Add(racingWeek);
									}
									else
										series.mWeeks.Add(racingWeek);

									int totalWeekIdx = racingWeek.TotalWeekIdx;
									DecodeTotalWeekIdx(totalWeekIdx, var curYear, var curSeason, var curWeek);

									/*if ((curYear == 2021) && (curSeason+1 == 4))
									{
										NOP!();
									}*/
								}

								int weekDayIdx = (int)sessionDate.DayOfWeek;
								weekDayIdx = (weekDayIdx + 5)  % 7;
								while (weekDayIdx >= racingWeek.mRacingDays.Count)
									racingWeek.mRacingDays.Add(null);

								if ((weekDayIdx < 6) || (racingWeek.mTrackId == -1)) // Try to not catch rollover
									racingWeek.mTrackId = trackId;

								var racingDay = racingWeek.mRacingDays[weekDayIdx];
								if (racingDay == null)
									racingWeek.mRacingDays[weekDayIdx] = racingDay = new RacingDay();

								racingSession = null;
								if (racingDay.mSessions.TryAdd(sessionId, var sessionIdPtr, var sessionPtr))
								{
									racingSession = *sessionPtr = new RacingSession();
									racingSession.mSessionDate = sessionDate;
								}
								else
									racingSession = *sessionPtr;
								
								racingSubSession = new RacingSubSession();
								racingSubSession.mId = subSessionId;

								racingSession.mSubSessions.Add(racingSubSession);
							}

							if (racingSubSession.mCarClassDict.TryAddAlt(carClass, var carClassNamePtr, var carClassPtr))
							{
								*carClassNamePtr = new String(carClass);
								var carClassEntry = *carClassPtr = new CarClassEntry();
							}
							racingSubSession.mHighestIR = Math.Max(racingSubSession.mHighestIR, oldIRating);

							CarEntry carEntry;
							carEntry.mIR = oldIRating;

							float ParseLapTime(StringView lapTimeStr)
							{
								int timeColonPos = lapTimeStr.IndexOf(':');
								if (timeColonPos != -1)
									return int.Parse(lapTimeStr.Substring(0, timeColonPos)).GetValueOrDefault()*60 + float.Parse(lapTimeStr.Substring(timeColonPos + 1)).GetValueOrDefault();
								else
									return float.Parse(lapTimeStr).GetValueOrDefault();
							}

							carEntry.mAvgLapTime = ParseLapTime(avgLapTime);
							carEntry.mFastestLapTime = ParseLapTime(fastestLapTime);

							var carClassEntry = *carClassPtr;
							if (carClassEntry.mCarDict.TryAddAlt(carName, var carNamePtr, var listPtr))
							{
								*carNamePtr = new String(carName);
								*listPtr = new List<CarEntry>();
							}
							(*listPtr).Add(carEntry);

							//Console.WriteLine("DateTimeOffset (other format) = {0:dd} {0:MMMM} {0:yyyy}, {0:hh}:{0:mm}:{0:ss} {0:tt} ", dt);
						}

						hadResults = true;
						prevSubSesssionId = subSessionId;
					}

					if (mStatsTransferCount > prevTransferCount)
					{
						Console.Write($" [{mStatsTransferCount - prevTransferCount} dl]");
					}

					Console.WriteLine();

					if (!hadResults)
						break;
				}
			}
		}

		class CarClassWeekInfo
		{
			public String mOut = new String() ~ delete _;
			public Dictionary<StringView, List<CarEntry>> mCarEntries = new .() ~ DeleteDictionaryAndValues!(_);
		}
		
		struct UserCountKey : IHashable
		{
			public SeriesKind mSeriesKind;
			public int32 mYear;
			public int32 mSeason;
			public int32 mWeek;

			public int32 TotalWeekIdx
			{
				get
				{
					return mYear * 52 + mSeason * 13 + mWeek;
				}
			}

			public int GetHashCode()
			{
				return (mYear*52 + mSeason*13 + mWeek) * 4 + (int)mSeriesKind;
			}
		}

		public void DecodeTotalWeekIdx(int totalWeekIdx, out int32 year, out int32 season, out int32 week)
		{
			year = (.)(totalWeekIdx / 52);
			season = (.)(totalWeekIdx / 13) % 4;
			week = (.)(totalWeekIdx % 13);
		}

		public void WriteCachedText(StringView path, StringView text)
		{
			if (mCache.TryAddAlt(path, var keyPtr, var valuePtr))
			{
				*keyPtr = new String(path);
				CacheEntry cacheEntry = new CacheEntry();
				cacheEntry.mKey = *keyPtr;
				cacheEntry.mData = new String(text);
				*valuePtr = cacheEntry;
			}
			else
			{
				var cacheEntry = *valuePtr;
				bool matches;
				if (cacheEntry.mData != null)
					matches = cacheEntry.mData == text;
				else
					matches = cacheEntry.Get(.. scope .()) == text;
				if ((matches) && (File.Exists(path)))
					return;
				if (cacheEntry.mData == null)
					cacheEntry.MakeEmpty();
				cacheEntry.mData.Set(text);
				cacheEntry.mDirty = true;
			}

			File.WriteAllText(path, text);
		}
		String cHtmlHeader =
			"""
			<html lang="en">
			<title>iRacing Statistics</title>
			<meta name="google" content="notranslate">
			<style>
			a:link {
				color: #0000FF;
				text-decoration: none;
			}

			a:visited {
				color: #0000FF;
				text-decoration: none;
			}

			a:hover {
				color: #6060FF;
				text-decoration: none;
			}

			a:active {
				color: #0000FF;
				text-decoration: none;
			}

			.slidecontainer {
			}

			.slider {
				width: 440px;
				-ms-transform: translateY(3px);
				transform: translateY(3px);
			}

			</style>
			""";
		String cHtmlFooter =
			"""
			<br><a href=about.html>About</a>
			</body></html>
			""";


		public void Analyze()
		{
			/*String[] seriesNames = scope .(
				"VRS GT Sprint Series",
				"Ruf GT3 Challenge",
				"Ferrari GT3 Challenge - Fixed",
				"Porsche iRacing Cup",
				"LMP2 Prototype Challenge - Fixed",
				"Pure Driving School European Sprint Series",
				"IMSA Hagerty iRacing Series");*/

			int csvIdx = 0;

			String[] seriesKindNames = scope .("Road", "Oval", "Dirt Road", "Dirt Oval");

			Dictionary<UserCountKey, int> seasonUserCountDict = scope .();

			int highestTotalWeekIdx = 0;
			int lowestTotalWeekIdx = int.MaxValue;

			List<String> seriesNames = scope .();
			seriesNames.AddRange(mSeriesDict.Keys);
			seriesNames.Sort(scope (lhs, rhs) => lhs.CompareTo(rhs, true));

			void AddKindNav(String outStr, int32 totalWeekIdx, SeriesKind seriesKind = .Unknown)
			{
				DecodeTotalWeekIdx(totalWeekIdx, var curYear, var curSeason, var curWeek);
				outStr.AppendF("""
					<table style=\"border-spacing: 6px 0px;\">
					<tr>
					""");
				String[] seriesHtmlNames = scope .(scope $"road", scope $"oval", scope $"dirtroad", scope $"dirtoval");
				for (var seriesHtmlName in seriesHtmlNames)
				{
					seriesHtmlName.AppendF($"_{curYear}_S{curSeason+1}W{curWeek+1}");
					if ((totalWeekIdx == highestTotalWeekIdx) && (@seriesHtmlName == 0))
						seriesHtmlName.Set("index");
				}

				for (int i in -1..<4)
				{
					outStr.AppendF("<td width=200px style=\"text-align: center;\">");
					if (i == -1)
					{
						DecodeTotalWeekIdx(highestTotalWeekIdx, var highYear, var highSeason, var highWeek);
						if (totalWeekIdx == highestTotalWeekIdx)
							outStr.AppendF($"{highYear} S{highSeason+1}W{highWeek+1}");
						else
							outStr.AppendF($"<a href=index.html>{highYear} S{highSeason+1}W{highWeek+1}</a>");
					}
					else if (i == (.)seriesKind)
					{
						outStr.AppendF($"{seriesKindNames[i]}");
					}
					else
					{
						outStr.AppendF($"<a href={seriesHtmlNames[i]}.html>{seriesKindNames[i]}</a>");
					}
					outStr.AppendF("</td>");
				}

				outStr.AppendF("</tr></table><hr><br>\n");
			}

			// Generate per-series htmls 
			for (var seriesName in seriesNames)
			{
				var series = mSeriesDict[seriesName];

				if (series.mKind == .Unknown)
				{
					if (series.mCurrentSeasonId != 0)
					{
						Console.WriteLine($"WARNING: Uncategorized current series: {series.mName}");
					}

					continue;
				}

				if (series.mWeeks.IsEmpty)
					continue;

				String outStr = scope .();
				String carCSV = scope .();
				carCSV.Append("Num,Season,PeakUsers\n");

				series.mWeeks.Sort(scope (lhs, rhs) => lhs.TotalWeekIdx <=> rhs.TotalWeekIdx);
				var lastWeek = series.mWeeks.Back;

				//var localDateTime = lastWeek.mRacingDays.Back;
				//Console.WriteLine("DateTimeOffset (other format) = {0:dd} {0:MMMM} {0:yyyy}, {0:hh}:{0:mm}:{0:ss} {0:tt} ", dt);

				Console.WriteLine($"{series.mName:60} {lastWeek.mSeasonYear} S{lastWeek.mSeasonNum+1}W{lastWeek.mWeekNum+1}");
				outStr.AppendF($"{cHtmlHeader}<body style=\"font-family: sans-serif\">");
				AddKindNav(outStr, lastWeek.TotalWeekIdx);

				outStr.AppendF("<table><td style=\"padding: 0px; height: 22px;\">");

				if (series.mLicense != .Unknown)
				{
					outStr.AppendF($"<img src=images/License{series.mLicense}.png />");
				}

				outStr.AppendF($"</td><td style=\"text-align: center;\">{series.mName}</td></table>\n");

				if (series.mID != null)
				{
					if (File.Exists(scope $"html/images/{series.mID}.jpg"))
						outStr.AppendF($"<img src=images/{series.mID}.jpg /><br>");
				}

				/*for (var racingDay in lastWeek.mRacingDays)
				{
					if (racingDay == null)
						continue;

					List<RacingSession> sessions = scope .(racingDay.mSessions.Values);
					sessions.Sort(scope (lhs, rhs) => (int)(lhs.mSessionDate - rhs.mSessionDate).TotalMilliseconds);

					for (var session in sessions)
					{
						var localTime = session.mSessionDate.ToLocalTime();
						outStr.AppendF($"{localTime:MM}/{localTime:dd}/{localTime:yyyy} {localTime:hh}:{localTime:mm} {localTime:tt}");
						for (var subSession in session.mSubSessions)
							outStr.AppendF($" {subSession.mIRHigh/1000.0:0.0}");
						outStr.AppendF("<br>\n");
					}
				}*/

				outStr.AppendF("<br><table style=\"border-spacing: 2px 0px;\"><tr><td>Season</td><td>Track</td><td colspan=2 style=\"text-align: center;\">Peak</td><td colspan=2 style=\"text-align: center;\">Max</td></tr>\n");

				HashSet<StringView> seenCarClassSet = scope .();

				float totalFieldMaxAvg = 1;
				PassLoop: for (int pass < 2)
				{
					WeekLoop: for (int weekIdx in (0..<series.mWeeks.Count).Reversed)
					{
						List<int32> splitMaxes = scope .();
						List<int32> fieldMaxes = scope .();

						var racingWeek = series.mWeeks[weekIdx];
						
						String displayTrackName = scope String();
						if (mTrackNames.TryGetValue(racingWeek.mTrackId, var trackName))
							displayTrackName.Set(trackName);
						else
							displayTrackName.AppendF($"#{racingWeek.mTrackId}");

						int curIRDivIdx = 1;

						String weekInfoFilePath = scope $"{series.SafeName}_{racingWeek.mSeasonYear}_S{racingWeek.mSeasonNum+1}W{racingWeek.mWeekNum+1}.html";
						String weekOutStr = scope .();
						weekOutStr.AppendF(
							$"""
							{cHtmlHeader}
							<script>
							function AddTime(timeStr)
							{{
								let date = new Date(timeStr);
								let dateText = date.toLocaleDateString();
								let timeText = date.toLocaleTimeString([], {{hour: '2-digit', minute:'2-digit'}});
								document.write(dateText + " " + timeText);
							}}

							function SetCookie(cname, cvalue)
							{{
								const d = new Date();
								var exdays = 90
								d.setTime(d.getTime() + (exdays * 24 * 60 * 60 * 1000));
								let expires = "expires="+d.toUTCString();
								var cookie = cname + "=" + cvalue + ";" + expires + ";path=/";
								document.cookie = cookie;
							}}

							function GetCookie(cname)
							{{
								let name = cname + "=";
								let ca = document.cookie.split(';');
								for(let i = 0; i < ca.length; i++)
								{{
									let c = ca[i];
									while (c.charAt(0) == ' ')
										c = c.substring(1);
									if (c.indexOf(name) == 0)
										return c.substring(name.length, c.length);
								}}
								return "";
							}}

							gIR = parseInt(GetCookie("ir")) + 0;
							if (gIR == 0)
								gIR = 2000;
							gAvgTimes = [];
							gFastTimes = [];
							gCarClasses = [];
							gCarClasses["ALL"] = "ALL";
							</script>
							<body style=\"font-family: sans-serif\">
							""");

						AddKindNav(weekOutStr, racingWeek.TotalWeekIdx);
						weekOutStr.AppendF($"<a href=\"{series.SafeName}.html\">{series.mName}</a> {racingWeek.mSeasonYear} S{racingWeek.mSeasonNum+1}W{racingWeek.mWeekNum+1} {displayTrackName}<br><br>\n");

						weekOutStr.AppendF(
							$"""
							<div class="slidecontainer" id="irSlider">
							  Laptime iRating <input type="range" min="5" max="60" value="20" class="slider" id="irSelect"> <div id="ir0" style="display:inline"></div>
							</div><br>

							<script>

							function FixIR(elem, ir)
							{{
								var text = elem.innerHTML;
								var dotIdx = text.indexOf('.');
								var spaceIdx = text.lastIndexOf(' ', dotIdx);
								var kIdx = text.indexOf('k', dotIdx);
								elem.innerHTML = text.substring(0, spaceIdx + 1) + (ir / 1000.0).toFixed(1) + "k" + text.substring(kIdx + 1);
							}}

							function TimeToStr(totalSeconds)
							{{
								var min = Math.trunc(totalSeconds / 60);
								var secStr = (totalSeconds - min * 60).toFixed(3);
								var str = "";
								if (min > 0)
								{{
									str += min;
									str += ":";
									if (secStr.indexOf('.') == 1)
										str += "0";
								}}
								str += secStr;
								return str;
							}}

							function GetExpectedTime(expectedTimes, ir)
							{{
								var cExpectInterval = 200;
								var leftTime = expectedTimes[Math.trunc(ir / cExpectInterval)];
								var rightTime = expectedTimes[Math.min(Math.trunc(ir / cExpectInterval) + 1, expectedTimes.length - 1)];
								var pct = (ir % cExpectInterval) / cExpectInterval;
								return (leftTime + (rightTime - leftTime)*pct) / 1000.0;
							}}

							function IRChanged()
							{{
								var irSlider = document.getElementById("irSelect");
								gIR = irSlider.value * 100;
								SetCookie("ir", gIR);
								for (var i = 0; true; i++)
								{{
									var elem = document.getElementById("ir" + i);
									if (elem == null)
										break;
									FixIR(elem, gIR);
								}}

								var bestAvgTime = [];
								var bestFastTime = [];

								for (var carName in gAvgTimes)
								{{
									var carClass = gCarClasses[carName];
									var avgTime = GetExpectedTime(gAvgTimes[carName], gIR);
									if ((bestAvgTime[carClass] == undefined) || (avgTime < bestAvgTime[carClass]))
										bestAvgTime[carClass] = avgTime;
									var fastTime = GetExpectedTime(gFastTimes[carName], gIR);
									if ((bestFastTime[carClass] == undefined) || (fastTime < bestFastTime[carClass]))
										bestFastTime[carClass] = fastTime;
								}}

								for (var carName in gAvgTimes)
								{{
									var carClass = gCarClasses[carName];
									var avgTime = GetExpectedTime(gAvgTimes[carName], gIR);
									var element = document.getElementById("AVGLAP:" + carName);
									var html = TimeToStr(avgTime);
									if (carName != "ALL")
										html += " (+" + TimeToStr(avgTime - bestAvgTime[carClass]) + ")";
									element.innerHTML = html;

									var fastTime = GetExpectedTime(gFastTimes[carName], gIR);
									var element = document.getElementById("FASTLAP:" + carName);
									html = TimeToStr(GetExpectedTime(gFastTimes[carName], gIR));
									if (carName != "ALL")
										html += " (+" + TimeToStr(fastTime - bestFastTime[carClass]) + ")";
									element.innerHTML = html;
								}}
							}}

							document.getElementById("irSelect").value = (gIR / 100).toFixed();
							document.getElementById("irSelect").oninput = IRChanged;
							</script>

							""");

						int32 timeIdx = 0;

						List<RacingSession> sessions = scope .();
						Dictionary<String, CarClassWeekInfo> carClassWeekInfos = scope .();

						defer
						{
							for (var kv in carClassWeekInfos)
							{
								delete kv.key;
								delete kv.value;
							}
						}

						CarClassWeekInfo AddCarClassStr(StringView carClass, StringView outStr)
						{
							if (carClassWeekInfos.TryAddAlt(carClass, var keyPtr, var valuePtr))
							{
								*keyPtr = new String(carClass);
								*valuePtr = new CarClassWeekInfo();
							}
							var carClassWeekInfo = *valuePtr;
							carClassWeekInfo.mOut.Append(outStr);
							return carClassWeekInfo;
						}

						for (var racingDay in racingWeek.mRacingDays)
						{
							if (racingDay == null)
								continue;

							for (var session in racingDay.mSessions.Values)
								sessions.Add(session);
							
							int32 splitMax = 0;
							int32 fieldMax = 0;
							for (var racingSession in racingDay.mSessions.Values)
							{
								splitMax = Math.Max(splitMax, (.)racingSession.mSubSessions.Count);

								int32 fieldCount = 0;
								for (var racingSubSession in racingSession.mSubSessions)
								{
									for (var carClassEntry in racingSubSession.mCarClassDict.Values)
									{
										for (var carList in carClassEntry.mCarDict.Values)
											fieldCount += (.)carList.Count;
									}
									//fieldCount += racingSubSession.mSizeOfField;
								}
								fieldMax = Math.Max(fieldMax, fieldCount);
							}
							splitMaxes.Add(splitMax);
							fieldMaxes.Add(fieldMax);
						}

						//sessions.Sort(scope (lhs, rhs) => (int)(rhs.mSessionDate.Ticks/1000000000 - lhs.mSessionDate.Ticks/1000000000));
						sessions.Sort(scope (lhs, rhs) => rhs.mSessionDate.Ticks <=> lhs.mSessionDate.Ticks);

						int totalCarCount = 0;
						for (var session in sessions)
						{
							var utcTime = session.mSessionDate;
							//var localTime = session.mSessionDate.ToLocalTime();
							seenCarClassSet.Clear();

							session.mSubSessions.Sort(scope (lhs, rhs) => rhs.mHighestIR <=> lhs.mHighestIR);

							for (var subSession in session.mSubSessions)
							{
								for (var carClassKV in subSession.mCarClassDict)
								{
									if (seenCarClassSet.Add(carClassKV.key))
									{
										int carCount = 0;
										for (var countSubSession in session.mSubSessions)
										{
											if (countSubSession.mCarClassDict.TryGetValue(carClassKV.key, var countCarClass))
											{
												for (var countCarEntries in countCarClass.mCarDict.Values)
													carCount += (.)countCarEntries.Count;
											}
										}

										AddCarClassStr(carClassKV.key, scope
											$"""
											<tr><td id=\"time{timeIdx++}\" nowrap><script>AddTime(\"{utcTime:yyyy}-{utcTime:MM}-{utcTime:dd}T{utcTime:HH}:{utcTime:mm}Z\");</script></td>
											<td style=\"text-align: right;\">{carCount}</td>
											""");
									}
									var carClass = carClassKV.value;

									int irHigh = int.MinValue;
									int irLow = int.MaxValue;

									for (var carEntries in carClass.mCarDict.Values)
									{
										for (var carEntry in carEntries)
										{
											if (carEntry.mIR > 0)
											{
												irLow = Math.Min(irLow, carEntry.mIR);
												irHigh = Math.Max(irHigh, carEntry.mIR);
												totalCarCount++;
											}
										}
									}

									if (irHigh < 0)
										irHigh = 0;
									irLow = Math.Min(irLow, irHigh);

									var carClassWeekInfo = AddCarClassStr(carClassKV.key, scope $"<td nowrap><a href=https://members.iracing.com/membersite/member/EventResult.do?&subsessionid={subSession.mId}>{irLow/1000.0:0.0}k-{irHigh/1000.0:0.0}k</a></td>");

									for (var carCountKV in carClass.mCarDict)
									{
										if (carClassWeekInfo.mCarEntries.TryAdd(carCountKV.key, var keyPtr, var valuePtr))
										{
											*valuePtr = new List<CarEntry>();
										}
										(*valuePtr).AddRange(carCountKV.value);
									}
								}
							}

							for (var carClass in seenCarClassSet)
								AddCarClassStr(carClass, "</tr>");
						}

						if (pass == 0)
						{
							UserCountKey countKey = .() { mYear = racingWeek.mSeasonYear, mSeason = racingWeek.mSeasonNum, mWeek = racingWeek.mWeekNum, mSeriesKind = series.mKind };
							seasonUserCountDict.TryAdd(countKey, var keyPtr, var valuePtr);
							*valuePtr += totalCarCount;
						}

						splitMaxes.Sort();
						fieldMaxes.Sort();

						if (racingWeek.mRacingDays.Count > 0)
						{
							racingWeek.mSplitMax = splitMaxes.Back;
							racingWeek.mFieldMax = fieldMaxes.Back;
							racingWeek.mSplitPeak = splitMaxes[splitMaxes.Count / 2];
							racingWeek.mFieldPeak = fieldMaxes[fieldMaxes.Count / 2];
							totalFieldMaxAvg = Math.Max(totalFieldMaxAvg, racingWeek.mFieldPeak);
						}

						/*if (displayTrackName.Length > 40)
						{
							displayTrackName.RemoveToEnd(40);
							displayTrackName.Append("...");
						}
						while (displayTrackName.Length < 44)
							displayTrackName.Append(' ');*/

						bool GetGoodLapTime(List<CarEntry> carEntries, function float(CarEntry entry) selector, out float goodLapTime, out int goodIR)
						{
							if (carEntries.IsEmpty)
							{
								goodLapTime = float.MaxValue;
								goodIR = 0;
								return false;
							}

							carEntries.Sort(scope (lhs, rhs) =>
								{
									var selLHS = selector(lhs);
									var selRHS = selector(rhs);
									if (selLHS == 0)
										return 1;
									if (selRHS == 0)
										return -1;
									return selLHS <=> selRHS;
								});

							double timeTotal = 0;
							int irTotal = 0;

							int medianStart = carEntries.Count / 20;
							int medianEnd = carEntries.Count / 10;

							for (int i = medianStart; i <= medianEnd; i++)
							{
								var carEntry = carEntries[i];
								timeTotal += selector(carEntry);
								irTotal += carEntry.mIR;
							}
							goodLapTime = (float)(timeTotal / (medianEnd - medianStart + 1));
							goodIR = irTotal / (medianEnd - medianStart + 1);
							return true;
						}

						void GetGoodLapTime(List<CarEntry> carEntries, String outStr, function float(CarEntry entry) selector, float bestTime, bool extraInfo)
						{
							if (!GetGoodLapTime(carEntries, selector, var goodLapTime, var goodIR))
								return;

							int minutes = (int)(goodLapTime / 60);
							float seconds = goodLapTime - minutes*60;

							String cmpString = scope .();
							cmpString.AppendF($"+{goodLapTime - bestTime:0.000}");
							outStr.AppendF($"{minutes}:{seconds:00.000}");
							if ((extraInfo) && (goodLapTime >= bestTime))
								outStr.AppendF($" {cmpString} {goodIR/1000.0:0.0}k");
						}

						List<String> carClassNames = scope .(carClassWeekInfos.Keys);
						carClassNames.Sort();
						for (var carClassName in carClassNames)
						{
							if (@carClassName.Index != 0)
								weekOutStr.AppendF("<br>\n");
							var carClassWeekInfo = carClassWeekInfos[carClassName];

							for (var carEntries in carClassWeekInfo.mCarEntries)
							{
								String str = scope .();
								for (var carEntry in carEntries.value)
								{
									if ((carEntry.mIR != 0) && (carEntry.mFastestLapTime != 0))
										str.AppendF($"{carEntry.mIR}, {carEntry.mFastestLapTime}\n");
								}
								var filePath = scope $"c:\\temp\\csv\\test{csvIdx++}.txt";
								File.WriteAllText(filePath, str);
								weekOutStr.AppendF($"<!-- {carEntries.key} {filePath} -->\n");
							}

							// Expected times
							{
								void TimesOut(StringView varName, StringView name, ExpectedTimes expectedTimes)
								{
									weekOutStr.AppendF($"{varName}[\"{name}\"] = [");
									for (var time in expectedTimes.mExpectedTimes)
									{
										if (@time.Index != 0)
											weekOutStr.Append(", ");
										weekOutStr.AppendF($"{(int)(time * 1000)}");
									}
									weekOutStr.AppendF("];\n");
								}

								ExpectedTimes totalAvgExpectedTimes = scope .();
								ExpectedTimes totalFastExpectedTimes = scope .();
								weekOutStr.Append("<script>\n");
								for (var carEntries in carClassWeekInfo.mCarEntries)
								{
									ExpectedTimes avgExpectedTimes = scope .();
									ExpectedTimes fastExpectedTimes = scope .();

									String str = scope .();
									for (var carEntry in carEntries.value)
									{
										if ((carEntry.mIR != 0) && (carEntry.mFastestLapTime != 0))
										{
											avgExpectedTimes.Add(carEntry.mIR, carEntry.mAvgLapTime);
											fastExpectedTimes.Add(carEntry.mIR, carEntry.mFastestLapTime);
											totalAvgExpectedTimes.Add(carEntry.mIR, carEntry.mAvgLapTime);
											totalFastExpectedTimes.Add(carEntry.mIR, carEntry.mFastestLapTime);
										}
									}

									if (carClassWeekInfo.mCarEntries.Count > 1)
									{
										avgExpectedTimes.Calc();
										fastExpectedTimes.Calc();
										TimesOut("gAvgTimes", carEntries.key, avgExpectedTimes);
										TimesOut("gFastTimes", carEntries.key, fastExpectedTimes);
										weekOutStr.AppendF($"gCarClasses[\"{carEntries.key}\"] = \"{carClassName}\";\n");
									}
								}
								totalAvgExpectedTimes.Calc();
								totalFastExpectedTimes.Calc();
								TimesOut("gAvgTimes", "ALL", totalAvgExpectedTimes);
								TimesOut("gFastTimes", "ALL", totalFastExpectedTimes);

								weekOutStr.Append("</script>\n");
							}

							weekOutStr.AppendF($"<b>{carClassName}</b><br>\n");
							weekOutStr.AppendF("<table style=\"border-spacing: 24px 0px;\">\n");
							List<CarEntry> totalCarEntries = scope .();
							for (var carCountKV in carClassWeekInfo.mCarEntries)
							{
								totalCarEntries.AddRange(carCountKV.value);
							}

							/*float bestAvgLapTime = float.MaxValue;
							float bestFastestLapTime = float.MaxValue;

							for (var carEntries in carClassWeekInfo.mCarEntries.Values)
							{
								GetGoodLapTime(carEntries, (entry) => entry.mAvgLapTime, var goodLapTime, var goodIR);
								if (goodLapTime > 0)
									bestAvgLapTime = Math.Min(goodLapTime, bestAvgLapTime);
								GetGoodLapTime(carEntries, (entry) => entry.mFastestLapTime, out goodLapTime, out goodIR);
								if (goodLapTime > 0)
									bestFastestLapTime = Math.Min(goodLapTime, bestFastestLapTime);
							}*/

							//String totalGoodAvgLapTime = GetGoodLapTime(totalCarEntries, .. scope .(), (entry) => entry.mAvgLapTime, bestAvgLapTime, false);
							//String totalGoodFastestLapTime = GetGoodLapTime(totalCarEntries, .. scope .(), (entry) => entry.mFastestLapTime, bestFastestLapTime, false);
							weekOutStr.AppendF(
								$"""
								<tr><td width=240px></td><td style=\"text-align: right;\">Count</td>
								<td style=\"text-align: center;\"><div id="ir{curIRDivIdx++}" style="display:inline"></div> Avg Lap</td>
								<td style=\"text-align: center;\"><div id="ir{curIRDivIdx++}" style="display:inline"></div> Fast Lap</td><tr/>
								<tr><td>Total Entries</td><td style=\"text-align: right;\">{totalCarEntries.Count}</td><td id="AVGLAP:ALL" style=\"text-align: left;\"></td><td id="FASTLAP:ALL" style=\"text-align: left;\"></td></tr>\n
								""");

							if (carClassWeekInfo.mCarEntries.Count > 1)
							{
								List<StringView> carNames = scope .(carClassWeekInfo.mCarEntries.Keys);
								carNames.Sort();
								for (var carName in carNames)
								{
									var carEntries = carClassWeekInfo.mCarEntries[carName];
									//String goodAvgLapTime = GetGoodLapTime(carEntries, .. scope .(), (entry) => entry.mAvgLapTime, bestAvgLapTime, true);
									//String goodFasestLapTime = GetGoodLapTime(carEntries, .. scope .(), (entry) => entry.mFastestLapTime, bestFastestLapTime, true);
									weekOutStr.AppendF("<tr height=0px><td colspan=7><div style=\"width: 100%; height:1px; background-color:#e0e0e0;\"></div></td></tr>\n");
									weekOutStr.AppendF(
										$"""
										<tr><td nowrap>{carName}</td><td style=\"text-align: right;\">{carEntries.Count}</td>
										<td id="AVGLAP:{carName}" style=\"text-align: left;\"></td>
										<td id="FASTLAP:{carName}" style=\"text-align: left;\"></td></tr>\n
										""");
								}
							}

							weekOutStr.AppendF("</table><br><br>\n<table style=\"border-spacing: 6px 0px;\">\n");
							weekOutStr.AppendF(carClassWeekInfo.mOut);
							weekOutStr.AppendF("</table>\n");
						}
						weekOutStr.Append("<script>IRChanged();</script>\n");
						weekOutStr.Append(cHtmlFooter);

						WriteCachedText(scope $"html/{weekInfoFilePath}", weekOutStr);

						if (pass == 0)
							carCSV.AppendF($"{weekIdx},{racingWeek.mFieldPeak:0.0},{racingWeek.mSeasonYear} S{racingWeek.mSeasonNum+1}W{racingWeek.mWeekNum+1}\\n{displayTrackName}\n");
						else
						{
							outStr.AppendF(
							$"""
							<tr height=0px><td colspan=5><div style=\"width: 100%; height:1px; background-color:#e0e0e0;\"></div></td></tr>
							<tr><td nowrap>{racingWeek.mSeasonYear} S{racingWeek.mSeasonNum+1}W{racingWeek.mWeekNum+1}&nbsp;</td><td width=600px style=\"position: relative;\">
							<div style=\"position: absolute; left:0; top:0; z-index: -1; border: 1px solid #e0e0e0; background-color: #eeeeee; height: calc(100% - 2px); width: calc({(int)((racingWeek.mFieldPeak / totalFieldMaxAvg) * 100):0.0}% - 4px);\">&nbsp;</div>
							<a href=\"{weekInfoFilePath}\">{displayTrackName}</a></td>
							<td style=\"text-align: right;\">&nbsp;{racingWeek.mFieldPeak}</td><td style=\"text-align: right;\">{racingWeek.mSplitPeak}&nbsp;</td>
							<td style=\"text-align: right;\">&nbsp;{racingWeek.mFieldMax}</td><td style=\"text-align: right;\">{racingWeek.mSplitMax}&nbsp;</td></tr>
							""");

							highestTotalWeekIdx = Math.Max(highestTotalWeekIdx, racingWeek.TotalWeekIdx);
							lowestTotalWeekIdx = Math.Min(lowestTotalWeekIdx, racingWeek.TotalWeekIdx);
						}
					}
				}

				outStr.AppendF("</table>\n");
				outStr.AppendF(cHtmlFooter);
				WriteCachedText(scope $"html/{series.SafeName}.html", outStr);
				//File.WriteAllText(scope $"html/{series.mName}.csv", carCSV);

				/*if (series.mName.Contains("VRS"))
				{
					ProcessStartInfo procInfo = scope ProcessStartInfo();
					//procInfo.UseShellExecute = false;
					procInfo.SetFileName("graph.exe");
					procInfo.CreateNoWindow = true;
					procInfo.SetArguments(scope $"html/{series.mName}.csv");

					Debug.WriteLine("ProcStartInfo {0} Verb: {1}", procInfo, procInfo.[Friend]mVerb);

					/*Process process = null;
					if (!case .Ok(out process) = Process.Start(procInfo))
						continue;
					defer(scope) delete process;
					String errors = scope String();
					if (case .Err = process.StandardError.ReadToEnd(errors))
						continue;*/

					String resultStr = scope String();
					SpawnedProcess process = scope SpawnedProcess();
					if (process.Start(procInfo) case .Err)
						continue;
					process.WaitFor();
				}*/
			}

			// Generate per-kind per-week html
			for (SeriesKind seriesKind = .Road; seriesKind <= .DirtOval; seriesKind++)
			{
				for (int32 totalWeekIdx in lowestTotalWeekIdx...highestTotalWeekIdx)
				{
					DecodeTotalWeekIdx(totalWeekIdx, var curYear, var curSeason, var curWeek);

					String[] seriesHtmlNames = scope .(scope $"road", scope $"oval", scope $"dirtroad", scope $"dirtoval");
					for (var seriesHtmlName in seriesHtmlNames)
					{
						seriesHtmlName.AppendF($"_{curYear}_S{curSeason+1}W{curWeek+1}");
						if ((totalWeekIdx == highestTotalWeekIdx) && (@seriesHtmlName == 0))
							seriesHtmlName.Set("index");
					}

					String kindOutStr = scope .();
					kindOutStr.AppendF(
						$"""
						{cHtmlHeader}
						<!-- Generated at {DateTime.UtcNow} UTC -->
						<body style=\"font-family: sans-serif\">
						""");

					kindOutStr.AppendF(
						$"""
						<table style=\"border-spacing: 6px 0px;\">
						<tr>
						""");

					AddKindNav(kindOutStr, totalWeekIdx, seriesKind);

					kindOutStr.AppendF(
						$"""
						<table style=\"border-spacing: 2px 0px;\">
						<tr><td width=78px></td><td>Series</td><td>Track</td><td colspan=2 style=\"text-align: center;\">Peak</td><td colspan=2 style=\"text-align: center;\">Max</td></tr>\n
						""");

					float totalFieldMaxAvg = 0;

					List<RacingWeek> seriesWeekList = scope .();
					for (var series in mSeriesDict.Values)
					{
						if (series.mKind != seriesKind)
							continue;

						for (var racingWeek in series.mWeeks)
						{
							if (racingWeek.TotalWeekIdx != totalWeekIdx)
								continue;

							seriesWeekList.Add(racingWeek);
							totalFieldMaxAvg = Math.Max(totalFieldMaxAvg, racingWeek.mFieldPeak);
						}
					}

					seriesWeekList.Sort(scope (lhs, rhs) => rhs.mFieldPeak <=> lhs.mFieldPeak);

					for (var racingWeek in seriesWeekList)
					{
						String displayTrackName = scope String();
						if (mTrackNames.TryGetValue(racingWeek.mTrackId, var trackName))
							displayTrackName.Set(trackName);
						else
							displayTrackName.AppendF($"#{racingWeek.mTrackId}");

						var series = racingWeek.mSeries;
						String weekInfoFilePath = scope $"{series.SafeName}_{racingWeek.mSeasonYear}_S{racingWeek.mSeasonNum+1}W{racingWeek.mWeekNum+1}.html";

						kindOutStr.AppendF(
							$"""
							<tr height=0px><td colspan=8><div style=\"width: 100%; height:1px; background-color:#e0e0e0;\"></div></td></tr>
							<tr><td style=\"padding: 0px; height: 22px;\" >
							""");

						if (series.mLicense != .Unknown)
						{
							kindOutStr.AppendF($"<img src=images/License{series.mLicense}.png />");
						}

						if (series.mID != null)
						{
							if (File.Exists(scope $"html/images/icon/{series.mID}.jpg"))
								kindOutStr.AppendF($"<img src=images/icon/{series.mID}.jpg />");
						}

						kindOutStr.AppendF(
						$"""
							</td>
							<td width=400px style=\"position: relative;\">
							<div style=\"position: absolute; left:0; top:0; z-index: -1; border: 1px solid #e0e0e0; background-color: #eeeeee; height: calc(100% - 2px); width: calc({(int)((racingWeek.mFieldPeak / totalFieldMaxAvg) * 100):0.0}% - 4px);\">&nbsp;</div>
							<a href=\"{series.SafeName}.html\">{series.mName}</a></td>
							<td><a href=\"{weekInfoFilePath}\">{displayTrackName}</a></td>
							<td style=\"text-align: right;\">&nbsp;{racingWeek.mFieldPeak}</td><td style=\"text-align: right;\">{racingWeek.mSplitPeak}&nbsp;</td>
							<td style=\"text-align: right;\">&nbsp;{racingWeek.mFieldMax}</td><td style=\"text-align: right;\">{racingWeek.mSplitMax}&nbsp;</td></tr>
							""");
					}

					kindOutStr.AppendF(
						$"""
						</table>
						<br>
						<a href={seriesKind}History.html>Previous Weeks</a>
						{cHtmlFooter}
						""");

					String outPath = scope $"html/{seriesHtmlNames[(.)seriesKind]}.html";
					WriteCachedText(outPath, kindOutStr);
				}

				String kindOutStr = scope .();
				kindOutStr.AppendF(
					$"""
					{cHtmlHeader}
					<body style=\"font-family: sans-serif\">
					<b>{seriesKindNames[(.)seriesKind]} Participation</b><br><br>
					<table style=\"border-spacing: 6px 0px;\">
					""");

				List<UserCountKey> keys = scope .();
				for (var key in seasonUserCountDict.Keys)
				{
					if (key.mSeriesKind == seriesKind)
						keys.Add(key);
				}
				keys.Sort(scope (lhs, rhs) => rhs.TotalWeekIdx <=> lhs.TotalWeekIdx);

				String[] seriesHtmlNames = scope .(scope $"road", scope $"oval", scope $"dirtroad", scope $"dirtoval");
				for (var key in keys)
				{
					var count = seasonUserCountDict[key];

					String url = scope $"{seriesHtmlNames[(.)seriesKind]}_{key.mYear}_S{key.mSeason+1}W{key.mWeek+1}";
					if ((seriesKind == .Road) && (key.TotalWeekIdx == highestTotalWeekIdx))
						url.Set("index");

					kindOutStr.AppendF($"<tr><td><a href={url}.html>{key.mYear} S{key.mSeason+1}W{key.mWeek+1}</a></td><td style=\"text-align: right;\">{count:N0}</td></tr>");
				}


				kindOutStr.AppendF("</table>\n");
				kindOutStr.AppendF(cHtmlFooter);
				WriteCachedText(scope $"html/{seriesKind}History.html", kindOutStr);
			}

			Console.WriteLine();
		}

		void ReadTrackNames()
		{
			var trackText = File.ReadAllText("Tracks.txt", .. scope .());
			for (var line in trackText.Split('\n'))
			{
				int spacePos = line.IndexOf(' ');
				if (spacePos == -1)
					continue;
				int32 trackId = int32.Parse(line.Substring(0, spacePos)).GetValueOrDefault();
				StringView trackName = line.Substring(spacePos + 1);
				if (mTrackNames.TryAdd(trackId, var idPtr, var namePtr))
				{
					*namePtr = new String(trackName);
				}
			}
		}

		void ReadSeries()
		{
			RacingSeries racingSeries = null;

			var seriesText = File.ReadAllText("Series.txt", .. scope .());
			for (var line in seriesText.Split('\n'))
			{
				int32 seriesId = int32.Parse(line).GetValueOrDefault();
				int32 seriesWeek = -1;
				StringView seriesName = default;
				StringView seriesRemap = default;
				SeriesKind seriesKind = .Unknown;

				if (line.StartsWith('\t'))
				{
					line.RemoveFromStart(1);
					var itr = line.Split(' ');
					switch (itr.GetNext().Value)
					{
					case "LICENSE":
						racingSeries.mLicense = Enum.Parse<RacingLicense>(itr.GetNext().Value).Value;
					case "ID":
						racingSeries.mID = new String(itr.GetNext().Value);
					}

					continue;
				}

				int spacePos = line.IndexOf(' ');
				if (spacePos > 0)
				{
					var seriesIdStr = line.Substring(0, spacePos);
					int wPos = seriesIdStr.IndexOf('W');
					if (wPos > 0)
					{
						seriesId = int32.Parse(seriesIdStr.Substring(0, wPos)).GetValueOrDefault();
						seriesWeek = int32.Parse(seriesIdStr.Substring(wPos + 1)).GetValueOrDefault() - 1;
					}
					else
						seriesId = int32.Parse(seriesIdStr).GetValueOrDefault();

					seriesName = line.Substring(spacePos + 1);
					int colonIdx = seriesName.IndexOf(':');
					if (colonIdx > 0)
					{
						StringView extraStr = seriesName.Substring(colonIdx + 1);
						extraStr.Trim();
						seriesName.RemoveToEnd(colonIdx);

						if (extraStr.Equals("Road", true))
						{
							seriesKind = .Road;
						}
						else if (extraStr.Equals("Oval", true))
						{
							seriesKind = .Oval;
						}
						else if (extraStr.Equals("DirtRoad", true))
						{
							seriesKind = .DirtRoad;
						}
						else if (extraStr.Equals("DirtOval", true))
						{
							seriesKind = .DirtOval;
						}
						else
						{
							seriesRemap = extraStr;
							seriesRemap.Trim();
						}
					}
					seriesName.Trim();
				}

				if (seriesName.IsEmpty)
					continue;

				if (seriesId != -1)
					mCurrentSeriesIdWeek[seriesId] = seriesWeek - 1;
				if (mSeriesDict.TryAddAlt(seriesName, var keyPtr, var valuePtr))
				{
					racingSeries = new .();
					racingSeries.mKind = seriesKind;
					racingSeries.mName.Set(seriesName);
					if (!seriesRemap.IsEmpty)
						racingSeries.mRemapName = new String(seriesRemap);
					// We purposely don't set mCurrentSeasonId - this must be recalculated
					*keyPtr = racingSeries.mName;
					*valuePtr = racingSeries;
				}
				else
					racingSeries = *valuePtr;
			}
		}

		void WriteSeries()
		{
			if (mSeriesDict.Count < 5)
				return; // Incomplete

			String data = scope .();
			List<StringView> seriesNames = scope .();
			for (var seriesName in mSeriesDict.Keys)
				seriesNames.Add(seriesName);
			seriesNames.Sort(scope (lhs, rhs) => lhs.CompareTo(rhs, true));

			for (var seriesName in seriesNames)
			{
				mSeriesDict.TryGetAlt(seriesName, var seriesNameStr, var racingSeries);
				data.AppendF($"{racingSeries.mCurrentSeasonId}");
				if (racingSeries.mCurrentSeasonWeek >= 0)
					data.AppendF($"W{racingSeries.mCurrentSeasonWeek+1}");
				data.AppendF($" {racingSeries.mName}");
				if (racingSeries.mRemapName != null)
					data.AppendF($" : {racingSeries.mRemapName}");
				else if (racingSeries.mKind != .Unknown)
					data.AppendF($" : {racingSeries.mKind}");
				data.AppendF("\n");

				if (racingSeries.mLicense != .Unknown)
					data.AppendF($"\tLICENSE {racingSeries.mLicense}\n");
				if (racingSeries.mID != null)
					data.AppendF($"\tID {racingSeries.mID}\n");
			}
			 
			File.WriteAllText("Series.txt", data);
		}

		public static int Main(String[] args)
		{
			Stopwatch sw = scope .();
			sw.Start();

			Program pg = scope .();

			bool doAnalyzeLoop = false;
			for (var arg in args)
			{
				if (arg == "-repeat")
					doAnalyzeLoop = true;
				if (arg == "-alwayscache")
					pg.mCacheMode = .AlwaysUseCache;
				if (arg == "-fast")
					pg.mLowestSeasonId = 3280; //2827
			}

			Console.WriteLine($"Starting. CacheMode: {pg.mCacheMode}");

			pg.ReadConfig();
			pg.ReadCache();

			//pg.WriteCache(true);

			pg.ReadSeries();
			pg.ReadTrackNames();
			pg.RetrieveSeriesDo();
			if (pg.mHighestSeasonId < 3300)
			{
				Console.WriteLine("Initialization failed");
				return 0;
			}

			pg.Retrieve();

			repeat
			{
				pg.Analyze();
			}
			while (doAnalyzeLoop);

			pg.WriteSeries();
			pg.WriteCache();

			sw.Stop();
			
			Console.WriteLine($"Total time: {sw.Elapsed}");
			Console.WriteLine($"{pg.mStatsGetCount} gets, {pg.mStatsTransferCount} not from cache.");

			ExpectedTimes.Finish();

			return 0;
		}
	}
}
