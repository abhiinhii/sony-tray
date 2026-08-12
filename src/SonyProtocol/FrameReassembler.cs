namespace SonyProtocol;

/// <summary>Accumulates raw socket bytes and yields complete decoded frames.</summary>
public sealed class FrameReassembler
{
    private readonly List<byte> _buffer = [];
    private readonly Queue<Frame> _frames = new();

    public void Feed(ReadOnlySpan<byte> chunk)
    {
        foreach (byte b in chunk) _buffer.Add(b);
        while (true)
        {
            int start = _buffer.IndexOf(Framing.StartMarker);
            if (start < 0)
            {
                _buffer.Clear();
                return;
            }
            int end = _buffer.IndexOf(Framing.EndMarker, start);
            if (end < 0)
            {
                // keep from start marker onward, wait for more bytes
                _buffer.RemoveRange(0, start);
                return;
            }
            byte[] candidate = [.. _buffer.GetRange(start, end - start + 1)];
            _buffer.RemoveRange(0, end + 1);
            if (Framing.TryUnpack(candidate, out Frame frame))
                _frames.Enqueue(frame);
            // else: corrupt between markers — drop and continue scanning
        }
    }

    public bool TryDequeue(out Frame frame) => _frames.TryDequeue(out frame);
}
