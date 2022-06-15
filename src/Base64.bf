using System;
using System.Collections;

namespace iStats
{
	class Base64
	{
		static String base64_table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

		/**
		 * base64_encode - Base64 encode
		 * @src: Data to be encoded
		 * @len: Length of the data to be encoded
		 * @out_len: Pointer to output length variable, or %NULL if not used
		 * Returns: Allocated buffer of out_len bytes of encoded data,
		 * or %NULL on failure
		 *
		 * Caller is responsible for freeing the returned buffer. Returned buffer is
		 * nul terminated to make it easier to use as a C string. The nul terminator is
		 * not included in out_len.
		 */
		public static Result<void> Encode(Span<uint8> inData, String outData)
		{
			char8* pos;
			uint8* end;
			uint8* inPtr;
			int olen;
			int line_len;

			olen = inData.Length * 4 / 3 + 4; /* 3-byte blocks to 4-byte */
			olen += olen / 72; /* line feeds */
			olen++; /* nul termination */
			if (olen < inData.Length)
				return .Err; /* integer overflow */

			int prevSize = outData.Length;
			outData.Append(' ', olen);
			char8* outPtr = &outData[prevSize];

			end = inData.EndPtr;
			inPtr = inData.Ptr;
			pos = outPtr;
			line_len = 0;
			while (end - inPtr >= 3)
			{
				*pos++ = base64_table[inPtr[0] >> 2];
				*pos++ = base64_table[((inPtr[0] & 0x03) << 4) | (inPtr[1] >> 4)];
				*pos++ = base64_table[((inPtr[1] & 0x0f) << 2) | (inPtr[2] >> 6)];
				*pos++ = base64_table[inPtr[2] & 0x3f];
				inPtr += 3;
				line_len += 4;
				if (line_len >= 72)
				{
					//*pos++ = '\n';
					line_len = 0;
				}
			}

			if (end - inPtr > 0)
			{
				*pos++ = base64_table[inPtr[0] >> 2];
				if (end - inPtr == 1)
				{
					*pos++ = base64_table[(inPtr[0] & 0x03) << 4];
					*pos++ = '=';
				} else
				{
					*pos++ = base64_table[((inPtr[0] & 0x03) << 4) |
						(inPtr[1] >> 4)];
					*pos++ = base64_table[(inPtr[1] & 0x0f) << 2];
				}
				*pos++ = '=';
				line_len += 4;
			}

			if (line_len != 0)
			{
				//*pos++ = '\n';
			}

			*pos = '\0';

			int actualSize = pos - outPtr;
			outData.Length = prevSize + actualSize;

			return .Ok;
		}


		/**
		 * base64_decode - Base64 decode
		 * @src: Data to be decoded
		 * @len: Length of the data to be decoded
		 * @out_len: Pointer to output length variable
		 * Returns: Allocated buffer of out_len bytes of decoded data,
		 * or %NULL on failure
		 *
		 * Caller is responsible for freeing the returned buffer.
		 */
		/*unsigned char * base64_decode(const unsigned char *src, size_t len,
						  size_t *out_len)
		{
			unsigned char dtable[256], *out, *pos, block[4], tmp;
			size_t i, count, olen;
			int pad = 0;

			os_memset(dtable, 0x80, 256);
			for (i = 0; i < sizeof(base64_table) - 1; i++)
				dtable[base64_table[i]] = (unsigned char) i;
			dtable['='] = 0;

			count = 0;
			for (i = 0; i < len; i++) {
				if (dtable[src[i]] != 0x80)
					count++;
			}

			if (count == 0 || count % 4)
				return NULL;

			olen = count / 4 * 3;
			pos = out = os_malloc(olen);
			if (out == NULL)
				return NULL;

			count = 0;
			for (i = 0; i < len; i++) {
				tmp = dtable[src[i]];
				if (tmp == 0x80)
					continue;

				if (src[i] == '=')
					pad++;
				block[count] = tmp;
				count++;
				if (count == 4) {
					*pos++ = (block[0] << 2) | (block[1] >> 4);
					*pos++ = (block[1] << 4) | (block[2] >> 2);
					*pos++ = (block[2] << 6) | block[3];
					count = 0;
					if (pad) {
						if (pad == 1)
							pos--;
						else if (pad == 2)
							pos -= 2;
						else {
							/* Invalid padding */
							os_free(out);
							return NULL;
						}
						break;
					}
				}
			}

			*out_len = pos - out;
			return out;
		}*/
	}
}