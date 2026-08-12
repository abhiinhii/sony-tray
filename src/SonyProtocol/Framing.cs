namespace SonyProtocol;

public enum MessageType : byte
{
    Ack = 0x01,
    DataMdr = 0x0C,
}

public readonly record struct Frame(MessageType Type, byte Seq, byte[] Payload);

public static class Framing
{
    public const byte StartMarker = 0x3E;
    public const byte EndMarker = 0x3C;
    private const byte EscapeSentry = 0x3D;

    public static byte Checksum(ReadOnlySpan<byte> data)
    {
        byte sum = 0;
        foreach (byte b in data) sum = unchecked((byte)(sum + b));
        return sum;
    }

    public static byte[] Escape(ReadOnlySpan<byte> data)
    {
        var result = new List<byte>(data.Length);
        foreach (byte b in data)
        {
            if (b is 0x3C or 0x3D or 0x3E)
            {
                result.Add(EscapeSentry);
                result.Add((byte)(b - 0x10)); // 0x3C→0x2C, 0x3D→0x2D, 0x3E→0x2E
            }
            else
            {
                result.Add(b);
            }
        }
        return [.. result];
    }

    public static byte[] Unescape(ReadOnlySpan<byte> data)
    {
        var result = new List<byte>(data.Length);
        for (int i = 0; i < data.Length; i++)
        {
            if (data[i] == EscapeSentry)
            {
                if (i + 1 >= data.Length || data[i + 1] is not (0x2C or 0x2D or 0x2E))
                    throw new FormatException("Invalid escape sequence");
                result.Add((byte)(data[++i] + 0x10));
            }
            else
            {
                result.Add(data[i]);
            }
        }
        return [.. result];
    }

    public static byte[] Pack(MessageType type, byte seq, ReadOnlySpan<byte> payload)
    {
        var body = new byte[payload.Length + 7];
        body[0] = (byte)type;
        body[1] = seq;
        // Int32BE payload length
        body[2] = (byte)(payload.Length >> 24);
        body[3] = (byte)(payload.Length >> 16);
        body[4] = (byte)(payload.Length >> 8);
        body[5] = (byte)payload.Length;
        payload.CopyTo(body.AsSpan(6));
        body[^1] = Checksum(body.AsSpan(0, body.Length - 1));
        return [StartMarker, .. Escape(body), EndMarker];
    }

    public static bool TryUnpack(ReadOnlySpan<byte> packed, out Frame frame)
    {
        frame = default;
        if (packed.Length < 2 || packed[0] != StartMarker || packed[^1] != EndMarker)
            return false;
        byte[] body;
        try { body = Unescape(packed[1..^1]); }
        catch (FormatException) { return false; }
        if (body.Length < 7)
            return false;
        if (Checksum(body.AsSpan(0, body.Length - 1)) != body[^1])
            return false;
        int declaredLen = body[2] << 24 | body[3] << 16 | body[4] << 8 | body[5];
        if (declaredLen != body.Length - 7)
            return false;
        frame = new Frame((MessageType)body[0], body[1], body[6..^1]);
        return true;
    }
}
