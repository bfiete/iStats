using System;
using System.Collections;
using System.IO;
using System.Diagnostics;

namespace iStats
{
	class StructuredCompress
	{
		enum Encode
		{
			Invalid,
			QuoteStr8,
			QuoteStr16,
			QuoteStr32,
			QuoteStrColon8,
			QuoteStrColon16,
			QuoteStrColon32,
			QuoteStrComma8,
			QuoteStrComma16,
			QuoteStrComma32,
			CR = 10,
			LF = 13,
			ZeroZero,
			ZeroComma,
			NegOneComma,
			QuoteComma,
			QuoteColon,
			Literal,
			Space=32,
		}

		struct StringTableEntry
		{
			public int32 mRefCount;
			public int32 mID;
		}

		Dictionary<StringView, StringTableEntry> mStringTable = new .() ~ delete _;
		List<uint8> mStream = new .() ~ delete _;

		public void Compress(StringView inData, List<uint8> outData)
		{
			int quoteStart = -1;
			bool prevWasSlash = false;
			for (int i < inData.Length)
			{
				char8 c = inData[i];
				if (prevWasSlash)
				{
					prevWasSlash = false;
					continue;
				}

				if (c == '\\')
				{
					prevWasSlash = true;
					continue;
				}

				if (c == '"')
				{
					if (quoteStart == -1)
					{
						quoteStart = i;
						continue;
					}

					StringView sv = inData.Substring(quoteStart + 1, i - quoteStart - 1);
					mStringTable.TryAdd(sv, var keyPtr, var valuePtr);
					valuePtr.mRefCount++;
					quoteStart = -1;
					continue;
				}
			}

			int stringTableCount = 0;

			int32 curId = 0;
			for (var kv in ref mStringTable)
			{
				if ((kv.valueRef.mRefCount > 1) && (kv.key.Length <= 0xFF))
				{
					kv.valueRef.mID = curId++;
					stringTableCount++;
				}
				else
					kv.valueRef.mID = -1;
			}

			DynMemStreamSequential stream = scope .(outData);

			stream.Write((uint8)1); // Version
			stream.Write((int32)inData.Length);
			stream.Write((int32)stringTableCount);
			for (var kv in ref mStringTable)
			{
				if (kv.valueRef.mID != -1)
				{
					outData.Add((uint8)kv.key.Length);
					stream.WriteStrUnsized(kv.key);
				}
			}

			int normalChars = 0;
			int strCount = 0;

			quoteStart = -1;
			prevWasSlash = false;
			for (int i < inData.Length)
			{
				char8 SafeNextC(int offset = 1)
				{
					if (i + offset < inData.Length)
						return inData[i + offset];
					return 0;
				}

				char8 c = inData[i];

				if (quoteStart != -1)
				{
					if (prevWasSlash)
					{
						prevWasSlash = false;
						continue;
					}

					if (c == '\\')
					{
						prevWasSlash = true;
						continue;
					}

					if (c == '"')
					{
						StringView sv = inData.Substring(quoteStart + 1, i - quoteStart - 1);
						if (mStringTable.TryGet(sv, var keyPtr, var valuePtr))
						{
							if (valuePtr.mID != -1)
							{
								strCount++;

								Encode encodeStart = .QuoteStr8;
								if ((i + 1 < inData.Length) && (inData[i + 1] == ':'))
								{
									encodeStart = .QuoteStrColon8;
									i++;
								}
								else if ((i + 1 < inData.Length) && (inData[i + 1] == ','))
								{
									encodeStart = .QuoteStrComma8;
									i++;
								}
								if (valuePtr.mID <= 0xFF)
								{
									outData.Add((uint8)encodeStart);
									outData.Add((uint8)valuePtr.mID);
								}
								else if (valuePtr.mID <= 0xFFFF)
								{
									outData.Add((uint8)encodeStart + 1);
									stream.Write<uint16>((uint16)valuePtr.mID);
								}
								else
								{
									outData.Add((uint8)encodeStart + 2);
									stream.Write<uint32>((uint32)valuePtr.mID);
								}
								quoteStart = -1;
								continue;
							}
						}

						//Debug.Write(StringView((.)inData.Ptr + quoteStart, i - quoteStart));
						outData.AddRange(.((.)inData.Ptr + quoteStart, i - quoteStart));
						quoteStart = -1;
					}
					else
						continue;
				}
				else if (c == '"')
				{
					quoteStart = i;
					continue;
				}	

				//Debug.Write(c);

				if ((c == '0') && (SafeNextC() == '0'))
				{
					outData.Add((uint8)Encode.ZeroZero);
					i++;
					continue;
				}
				if ((c == '0') && (SafeNextC() == ','))
				{
					outData.Add((uint8)Encode.ZeroComma);
					i++;
					continue;
				}
				if ((c == '-') && (SafeNextC() == '1') && (SafeNextC(2) == ','))
				{
					outData.Add((uint8)Encode.NegOneComma);
					i += 2;
					continue;
				}
				if ((c == '"') && (SafeNextC() == ','))
				{
					outData.Add((uint8)Encode.QuoteComma);
					i++;
					continue;
				}
				if ((c == '"') && (SafeNextC() == ':'))
				{
					outData.Add((uint8)Encode.QuoteColon);
					i++;
					continue;
				}

				normalChars++;
				if ((c < ' ') && (c != '\r') && (c != '\n'))
					outData.Add((uint8)Encode.Literal);
				outData.Add((uint8)c);
				
			}
			//Debug.WriteLine();

			//Debug.WriteLine($"Compression rate: {(1.0f - outData.Count / (float)inData.Length)*100:0.0}");
		}
		
		public void Decompress(List<uint8> inData, String outData)
		{
			List<StringView> stringTable = scope .();

			DynMemStream stream = scope .(inData);

#unwarn
			int32 version = stream.Read<uint8>().Value;
			int32 outLen = stream.Read<int32>().Value;

			int32 stringTableCount = stream.Read<int32>();
			for (int i < stringTableCount)
			{
				int32 len = stream.Read<uint8>().Value;
				int pos = stream.Position;
				stringTable.Add(.((char8*)inData.Ptr + pos, len));
				stream.Position = pos + len;
			}

			uint8* inPtr = inData.Ptr + stream.Position;
			char8* outPtr = outData.PrepareBuffer(outLen);
			char8* outEnd = outPtr + outLen;

			while (outPtr < outEnd)
			{
				void AddStringTable(int byteCount)
				{
					int idx = *(inPtr++);
					if (byteCount == 2)
						idx = idx | ((int)*(inPtr++)) << 8;
					if (byteCount == 4)
					{
						idx = idx | ((int)*(inPtr++)) << 16;
						idx = idx | ((int)*(inPtr++)) << 24;
					}
					*(outPtr++) = '\"';
					StringView sv = stringTable[idx];
					Internal.MemCpy(outPtr, sv.[Friend]mPtr, sv.[Friend]mLength);
					outPtr += sv.[Friend]mLength;
					*(outPtr++) = '\"';
				}

				char8 c = (char8)*(inPtr++);
				switch ((Encode)c)
				{
				case .QuoteStr8:
					AddStringTable(1);
				case .QuoteStr16:
					AddStringTable(2);
				case .QuoteStr32:
					AddStringTable(4);
				case .QuoteStrColon8:
					AddStringTable(1);
					*(outPtr++) = ':';
				case .QuoteStrColon16:
					AddStringTable(2);
					*(outPtr++) = ':';
				case .QuoteStrColon32:
					AddStringTable(4);
					*(outPtr++) = ':';
				case .QuoteStrComma8:
					AddStringTable(1);
					*(outPtr++) = ',';
				case .QuoteStrComma16:
					AddStringTable(2);
					*(outPtr++) = ',';
				case .QuoteStrComma32:
					AddStringTable(4);
					*(outPtr++) = ',';
				case .ZeroZero:
					*(outPtr++) = '0';
					*(outPtr++) = '0';
				case .ZeroComma:
					*(outPtr++) = '0';
					*(outPtr++) = ',';
				case .NegOneComma:
					*(outPtr++) = '-';
					*(outPtr++) = '1';
					*(outPtr++) = ',';
				case .QuoteComma:
					*(outPtr++) = '\"';
					*(outPtr++) = ',';
				case .QuoteColon:
					*(outPtr++) = '\"';
					*(outPtr++) = ':';
				case .Literal:
					*(outPtr++) = (char8)*(inPtr++);
				default:
					*(outPtr++) = c;
				}
			}
		}
	}
}
