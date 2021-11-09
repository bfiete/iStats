#pragma warning disable 168

using System;
using System.Collections;
using System.Diagnostics;

namespace iStats
{
	struct Point2
	{
		public double x;
		public double y;

		public this()
		{
			this = default;
		}

		public this(double x, double y)
		{
			this.x = x;
			this.y = y;
		}
	}

	class ExpectedTimes
	{
		public struct Entry
		{
			public int32 mIR;
			public float mTime;
		}

		/*public static float[51] cBasisPercentages = .(
			1.0404f, 1.0364f, 1.0376f, 1.0339f, 1.0283f, 1.0227f, 1.0177f, 1.0123f, 1.0071f, 1.003f, 1f, 0.9979f,
			0.9958f, 0.9943f, 0.9927f, 0.9912f, 0.99f, 0.989f, 0.988f, 0.987f, 0.9861f, 0.9857f, 0.9846f, 0.9839f,
			0.9831f, 0.9828f, 0.9827f, 0.9817f, 0.9812f, 0.9801f, 0.9796f, 0.9793f, 0.979f, 0.9782f, 0.9782f,
			0.9783f, 0.9775f, 0.9766f, 0.9763f, 0.9777f, 0.9758f, 0.9753f, 0.9735f, 0.9719f, 0.9731f, 0.9757f,
			0.9728f, 0.9732f, 0.9727f, 0.9776f, 0.9658f);*/

		public static float[51] cBasisPercentages = .(
			1.0507f, 1.0451f, 1.0395f, 1.0339f, 1.0283f, 1.0227f, 1.0177f, 1.0123f, 1.0071f, 1.003f, 1f, 0.9979f,
			0.9958f, 0.9943f, 0.9927f, 0.9912f, 0.99f, 0.989f, 0.988f, 0.987f, 0.9861f, 0.9857f, 0.9846f, 0.9839f,
			0.9831f, 0.9828f, 0.9823f, 0.9817f, 0.9812f, 0.9803f, 0.9796f, 0.9793f, 0.9790f, 0.9785f, 0.9782f,
			0.9780f, 0.9775f, 0.9766f, 0.9763f, 0.9760f, 0.9750f, 0.9746f, 0.9742f, 0.9736f, 0.9733f, 0.9732f,
			0.9731f, 0.9728f, 0.9727f, 0.9727f, 0.9727f);

		static List<float>[] cCalcBasisPercentages;

		public const int32 cExpectInterval = 200;
		public const int32 cExpectIntervalCount = 10000 / cExpectInterval + 1;
		public const int32 cBasisIR = 2000;
		public List<Entry> mEntries = new .() ~ delete _;
		public List<float> mExpectedTimes = new .() ~ delete _;
		public float mBasisTime;

		public float mMinTime;
		public float mMaxTime;

		public static void Finish()
		{
			if (cCalcBasisPercentages != null)
			{
				for (int intr < cExpectIntervalCount)
				{
					var list = cCalcBasisPercentages[intr];
					if (list.Count > 0)
					{
						list.Sort();
						Debug.Write("{:0.####}f, ", list[(list.Count - 1) / 2]);
					}
					else
						Debug.Write("0, ");
				}
				Debug.WriteLine();
			}
		}

		public void Add(int32 ir, float time)
		{
			Entry entry;
			entry.mIR = ir;
			entry.mTime = time;
			mEntries.Add(entry);

			if (mMaxTime == 0)
			{
				mMinTime = time;
				mMaxTime = time;
			}
			else
			{
				mMinTime = Math.Min(mMinTime, time);
				mMaxTime = Math.Max(mMinTime, time);
			}
		}

		public void Calc()
		{
			if (mEntries.Count == 0)
				return;

			mEntries.Sort(scope (lhs, rhs) => lhs.mIR <=> rhs.mIR);

			List<float>[] times = scope .[cExpectIntervalCount];
			for (int intr < cExpectIntervalCount)
				times[intr] = scope:: .();

			List<float> basisTimes = scope .();

			for (var entry in mEntries)
			{
				int intr = (.)Math.Round(entry.mIR / (float)cExpectInterval);
				if (intr >= cExpectIntervalCount)
					break;
				times[intr].Add(entry.mTime);
				float basisTime = entry.mTime / cBasisPercentages[intr];
				basisTimes.Add(basisTime);
			}

			basisTimes.Sort();
			mBasisTime = basisTimes[(basisTimes.Count - 1) / 2];

			for (int intr < cExpectIntervalCount)
			{
				var list = times[intr];

				var adjustedTime = mBasisTime * cBasisPercentages[intr];
				list.Add(adjustedTime);

				if (intr > 0)
				{
					// Adjust the previous entry to the new factor
					float prevExpectTime = mExpectedTimes[intr - 1];
					float adjustedExpectTime = prevExpectTime / cBasisPercentages[intr - 1] * cBasisPercentages[intr];
					list.Add(adjustedExpectTime);
				}

				if (intr > 1)
				{
					// Adjust the previous-previous entry to the new factor
					float prevExpectTime = mExpectedTimes[intr - 2];
					float adjustedExpectTime = prevExpectTime / cBasisPercentages[intr - 2] * cBasisPercentages[intr];
					list.Add(adjustedExpectTime);
				}

				if (list.Count > 0)
				{
					list.Sort(); 
					mExpectedTimes.Add(list[(list.Count - 1) / 2]);
				}
				else
					mExpectedTimes.Add(0);
			}

			for (int pass < 5)
			{
				for (int intr < cExpectIntervalCount)
				{
					if (intr + 2 < cExpectIntervalCount)
					{
						float exTime0 = mExpectedTimes[intr];
						float exTime1 = mExpectedTimes[intr + 1];
						float exTime2 = mExpectedTimes[intr + 2];

						if (pass > 0)
						{
							if (exTime1 > exTime0)
							{
								if (exTime2 < exTime0)
									mExpectedTimes[intr + 1] = Math.Lerp(exTime0, exTime2, 0.5f);
								else
									mExpectedTimes[intr + 1] = exTime0;
								continue;
							}
						}

						float expectAdjust0 = cBasisPercentages[intr + 1] / cBasisPercentages[intr];
						float expectAdjust1 = cBasisPercentages[intr + 2] / cBasisPercentages[intr + 1];

						float adjust0 = exTime1 / exTime0;
						float adjust1 = exTime2 / exTime1;

						//if ((Math.Abs(expectAdjust0 - adjust0) > 0.005f) || (adjust0 >= 1.0f))
						{
							//float newAdjust0 = Math.Lerp(adjust0, expectAdjust0, 0.3f);
							float newAdjust0 = Math.Lerp(adjust0, adjust1, 0.4f);

							float newTime1 = exTime0 * newAdjust0;
							mExpectedTimes[intr + 1] = newTime1;
						}
					}
				}
			}


			/*float basisBucketTime = mExpectedTimes[cBasisIR / cExpectInterval];
			if (cCalcBasisPercentages == null)
			{
				cCalcBasisPercentages = new .[cExpectIntervalCount];
				for (int intr < cExpectIntervalCount)
					cCalcBasisPercentages[intr] = new .();
			}

			if (basisBucketTime != 0)
			{
				for (int intr < cExpectIntervalCount)
				{
					if (mExpectedTimes[intr] != 0)
						cCalcBasisPercentages[intr].Add(mExpectedTimes[intr] / basisBucketTime);
				}
			}*/

			mMinTime = Math.Min(mMinTime, mBasisTime * cBasisPercentages[50]);
			mMaxTime = Math.Max(mMaxTime, mBasisTime * cBasisPercentages[0]);
		}

		public float GetExpectedTime(int ir)
		{
			float leftTime = mExpectedTimes[(ir / cExpectInterval)];
			float rightTime = mExpectedTimes[Math.Min((ir / cExpectInterval) + 1, mExpectedTimes.Count - 1)];
			return Math.Lerp(leftTime, rightTime, (ir % cExpectInterval) / (float)cExpectInterval);
		}
	}
}
