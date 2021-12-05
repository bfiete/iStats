using System.Collections;
using System;
using System.Diagnostics;

namespace iStats
{
	class Element
	{
		public Element mNext;
		public Element mPrev;
	}

	class DLIList<T> : IEnumerable<T> where T : var
	{
		public T mHead;
		public T mTail;
	
		public struct RemovableIterator : IEnumerator<T>
		{
			public T* mPrevNextPtr;
	
			public this(T* prevNextPtr)
			{						
				mPrevNextPtr = prevNextPtr;
			}
	
			public Result<T> GetNext() mut
			{
				T newNode = *mPrevNextPtr;			
				if (newNode == null)
					return .Err;
				mPrevNextPtr = &newNode.mNext;			
				return .Ok(newNode);
			}
		};
	
		public this()
		{
			mHead = null;
			mTail = null;
		}
	
		public void Size()
		{
			int size = 0;
			T checkNode = mHead;
			while (checkNode != null)
			{
				size++;
				checkNode = checkNode.mNext;
			}
		}
	
		public void PushBack(T node)
		{
			Debug.Assert(node.mNext == null);
	
			if (mHead == null)
				mHead = node;
			else
			{
				mTail.mNext = node;
				node.mPrev = mTail;
			}
			mTail = node;
		}
	
		public void AddAfter(T refNode, T newNode)
		{
			var prevNext = refNode.mNext;
			refNode.mNext = newNode;
			newNode.mPrev = refNode;
			newNode.mNext = prevNext;
			if (prevNext != null)
				prevNext.mPrev = newNode;
			if (refNode == mTail)
				mTail = newNode;
		}
	
		public void PushFront(T node)
		{
			if (mHead == null)
				mTail = node;
			else
			{
				mHead.mPrev = node;
				node.mNext = mHead;
			}
			mHead = node;
		}
	
		public T PopFront()
		{
			T node = mHead;
			mHead = node.mNext;
			mHead.mPrev = null;
			node.mNext = null;
			return node;
		}
	
		public void Remove(T node)
		{		
			if (node.mPrev == null)
			{
				Debug.Assert(mHead == node);
				mHead = node.mNext;
				if (mHead != null)
					mHead.mPrev = null;
			}
			else		
				node.mPrev.mNext = node.mNext;
	
			if (node.mNext == null)
			{
				Debug.Assert(mTail == node);
				mTail = node.mPrev;
				if (mTail != null)
					mTail.mNext = null;
			}
			else		
				node.mNext.mPrev = node.mPrev;					
	
			node.mPrev = null;
			node.mNext = null;
		}
	
		public void Replace(T oldNode, T newNode)
		{		
			if (oldNode.mPrev != null)
			{
				oldNode.mPrev.mNext = newNode;
				newNode.mPrev = oldNode.mPrev;
				oldNode.mPrev = null;
			}
			else
				mHead = newNode;
	
			if (oldNode.mNext != null)
			{
				oldNode.mNext.mPrev = newNode;
				newNode.mNext = oldNode.mNext;
				oldNode.mNext = null;
			}
			else
				mTail = newNode;
		}
	
		public void Clear()
		{
			T checkNode = mHead;
			while (checkNode != null)
			{
				T next = checkNode.mNext;
				checkNode.mNext = null;
				checkNode.mPrev = null;
				checkNode = next;
			}
	
			mHead = null;
			mTail = null;
		}
	
		public void ClearFast()
		{
			mHead = null;
			mTail = null;
		}
	
		public bool IsEmpty()
		{
			return mHead == null;
		}
	
		public RemovableIterator GetEnumerator()
		{
			return RemovableIterator(&mHead);
		}
	}
}
