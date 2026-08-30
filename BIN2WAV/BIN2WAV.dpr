program Bin2WAV;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes;

const
  { H68/TR binary tape format }
  LEADER_COUNT   = 680;
  SEPARATOR_COUNT = 25;
  H68_BLOCK_SIZE = 256;
  MARK_B = $42;  { 'B' }
  MARK_G = $47;  { 'G' }

  { Kansas City Standard / WAV }
  FRAME_RATE = 9600;
  ONES_FREQ  = 2400;
  ZERO_FREQ  = 1200;
  AMPLITUDE  = 128;
  CENTER     = 128;

type
  TByteArray = array of Byte;

procedure AppendByte(var Dest: TByteArray; B: Byte);
var
  N: Integer;
begin
  N := Length(Dest);
  SetLength(Dest, N + 1);
  Dest[N] := B;
end;

procedure AppendFF(var Dest: TByteArray; Count: Integer);
var
  I: Integer;
begin
  for I := 1 to Count do
    AppendByte(Dest, $FF);
end;

function HexToWord(S: string): Word;
var
  V: Integer;
begin
  S := Trim(S);
  if (Length(S) > 0) and (S[1] = '$') then
    Delete(S, 1, 1);

  if S = '' then
    raise Exception.Create('Address must be 0000..FFFF.');

  V := StrToInt('$' + S);

  if (V < 0) or (V > $FFFF) then
    raise Exception.Create('Address must be 0000..FFFF.');

  Result := Word(V);
end;

procedure MakeH68Data(
  const InFileName: string;
  StartAddress: Word;
  out H68: TByteArray;
  out DataSize: Int64;
  out BlockCount: Integer);
var
  InFile: TFileStream;
  Buffer: TByteArray;
  Remaining: Int64;
  BlockSize: Integer;
  Address: Word;
  Posn: Int64;
  I: Integer;
begin
  H68 := nil;
  BlockCount := 0;

  InFile := TFileStream.Create(
    InFileName,
    fmOpenRead or fmShareDenyWrite);
  try
    DataSize := InFile.Size;

    if DataSize = 0 then
      raise Exception.Create('Input file is empty.');

    if DataSize > $10000 - StartAddress then
      raise Exception.Create('Data exceeds 64K address space.');

    SetLength(Buffer, DataSize);
    InFile.ReadBuffer(Buffer[0], DataSize);
  finally
    InFile.Free;
  end;

  { 680 x FF leader }
  AppendFF(H68, LEADER_COUNT);

  Address := StartAddress;
  Remaining := DataSize;
  Posn := 0;

  while Remaining > 0 do
  begin
    Inc(BlockCount);

    if Remaining >= H68_BLOCK_SIZE then
      BlockSize := H68_BLOCK_SIZE
    else
      BlockSize := Integer(Remaining);

    { Block header: 'B', length-1, address MSB, address LSB }
    AppendByte(H68, MARK_B);

    { 256 bytes is represented by FF (= 255 + 1) }
    AppendByte(H68, Byte(BlockSize - 1));

    AppendByte(H68, Hi(Address));
    AppendByte(H68, Lo(Address));

    { Block data }
    for I := 0 to BlockSize - 1 do
      AppendByte(H68, Buffer[Posn + I]);

    { 25 x FF after every block }
    AppendFF(H68, SEPARATOR_COUNT);

    Inc(Posn, BlockSize);
    Dec(Remaining, BlockSize);
    Inc(Address, BlockSize);
  end;

  { End marker }
  AppendByte(H68, MARK_G);
end;

function MakeSquareWave(Freq, SampleRate: Integer): TByteArray;
var
  N, I, P: Integer;
begin
  N := SampleRate div Freq div 2;

  if N < 1 then
    raise Exception.Create('Invalid waveform frequency.');

  SetLength(Result, N * 2);
  P := 0;

  for I := 1 to N do
  begin
    Result[P] := CENTER - (AMPLITUDE div 2);
    Inc(P);
  end;

  for I := 1 to N do
  begin
    Result[P] := CENTER + (AMPLITUDE div 2);
    Inc(P);
  end;
end;

procedure AppendArray(var Dest: TByteArray; const Src: TByteArray);
var
  OldLen, I: Integer;
begin
  OldLen := Length(Dest);
  SetLength(Dest, OldLen + Length(Src));

  for I := 0 to Length(Src) - 1 do
    Dest[OldLen + I] := Src[I];
end;

procedure AppendRepeated(
  var Dest: TByteArray;
  const Src: TByteArray;
  Count: Integer);
var
  I: Integer;
begin
  for I := 1 to Count do
    AppendArray(Dest, Src);
end;

procedure MakePulses(
  const OneCycle, ZeroCycle: TByteArray;
  out OnePulse, ZeroPulse: TByteArray);
begin
  { 2400 Hz cycle x 8 = 32 samples = one '1' bit }
  { 1200 Hz cycle x 4 = 32 samples = one '0' bit }
  OnePulse := nil;
  ZeroPulse := nil;

  AppendRepeated(OnePulse, OneCycle, 8);
  AppendRepeated(ZeroPulse, ZeroCycle, 4);
end;

procedure EncodeByte(
  ByteVal: Byte;
  const OnePulse, ZeroPulse: TByteArray;
  var Encoded: TByteArray);
var
  Mask, I: Integer;
begin
  Encoded := nil;

  { Start bit = 0 }
  AppendArray(Encoded, ZeroPulse);

  { 8 data bits, LSB first }
  Mask := 1;
  for I := 0 to 7 do
  begin
    if (ByteVal and Mask) <> 0 then
      AppendArray(Encoded, OnePulse)
    else
      AppendArray(Encoded, ZeroPulse);

    Mask := Mask shl 1;
  end;

  { Two stop bits = 1 }
  AppendArray(Encoded, OnePulse);
  AppendArray(Encoded, OnePulse);
end;

procedure WriteWavHeader(
  Stream: TFileStream;
  DataSize: Int64);
var
  RiffID: array[0..3] of AnsiChar;
  WaveID: array[0..3] of AnsiChar;
  FmtID: array[0..3] of AnsiChar;
  DataID: array[0..3] of AnsiChar;
  ChunkSize: Cardinal;
  SubChunk1Size: Cardinal;
  AudioFormat: Word;
  NumChannels: Word;
  SampleRate: Cardinal;
  ByteRate: Cardinal;
  BlockAlign: Word;
  BitsPerSample: Word;
  FmtChunkSize: Cardinal;
  DS: Cardinal;
begin
  if DataSize > High(Cardinal) - 36 then
    raise Exception.Create('WAV file is too large.');

  DS := Cardinal(DataSize);

  RiffID := 'RIFF';
  WaveID := 'WAVE';
  FmtID  := 'fmt ';
  DataID := 'data';

  ChunkSize := 36 + DS;
  SubChunk1Size := 16;
  AudioFormat := 1;       { PCM }
  NumChannels := 1;
  SampleRate := FRAME_RATE;
  ByteRate := FRAME_RATE;
  BlockAlign := 1;
  BitsPerSample := 8;
  FmtChunkSize := 16;

  Stream.WriteBuffer(RiffID, 4);
  Stream.WriteBuffer(ChunkSize, 4);
  Stream.WriteBuffer(WaveID, 4);

  Stream.WriteBuffer(FmtID, 4);
  Stream.WriteBuffer(FmtChunkSize, 4);
  Stream.WriteBuffer(AudioFormat, 2);
  Stream.WriteBuffer(NumChannels, 2);
  Stream.WriteBuffer(SampleRate, 4);
  Stream.WriteBuffer(ByteRate, 4);
  Stream.WriteBuffer(BlockAlign, 2);
  Stream.WriteBuffer(BitsPerSample, 2);

  Stream.WriteBuffer(DataID, 4);
  Stream.WriteBuffer(DS, 4);
end;

procedure ConvertH68ToWAV(
  const H68: TByteArray;
  const OutFileName: string;
  out WavSamples: Int64);
var
  OneCycle, ZeroCycle: TByteArray;
  OnePulse, ZeroPulse: TByteArray;
  Encoded: TByteArray;
  OutFile: TFileStream;
  LeaderCount, I, J: Integer;
begin
  OneCycle := MakeSquareWave(ONES_FREQ, FRAME_RATE);
  ZeroCycle := MakeSquareWave(ZERO_FREQ, FRAME_RATE);

  MakePulses(OneCycle, ZeroCycle, OnePulse, ZeroPulse);

  { 5 seconds leader/trailer.
    9600 / 32 = 300 encoded bits/sec. }
  LeaderCount := (FRAME_RATE div Length(OnePulse)) * 5;

  WavSamples :=
    Int64(LeaderCount) * Length(OnePulse) +
    Int64(Length(H68)) * 10 * Length(OnePulse) +
    Int64(LeaderCount) * Length(OnePulse);

  OutFile := TFileStream.Create(OutFileName, fmCreate);
  try
    WriteWavHeader(OutFile, WavSamples);

    { Leader: 5 seconds of 2400 Hz carrier }
    for I := 1 to LeaderCount do
      OutFile.WriteBuffer(OnePulse[0], Length(OnePulse));

    { KCS encode the complete H68 byte stream }
    for I := 0 to Length(H68) - 1 do
    begin
      EncodeByte(H68[I], OnePulse, ZeroPulse, Encoded);
      OutFile.WriteBuffer(Encoded[0], Length(Encoded));
    end;

    { Trailer: 5 seconds of 2400 Hz carrier }
    for J := 1 to LeaderCount do
      OutFile.WriteBuffer(OnePulse[0], Length(OnePulse));

  finally
    OutFile.Free;
  end;
end;

procedure Convert(
  const InFileName, OutFileName: string;
  StartAddress: Word);
var
  H68: TByteArray;
  DataSize: Int64;
  BlockCount: Integer;
  WavSamples: Int64;
begin
  MakeH68Data(
    InFileName,
    StartAddress,
    H68,
    DataSize,
    BlockCount);

  ConvertH68ToWAV(
    H68,
    OutFileName,
    WavSamples);

  Writeln('BIN -> H68 -> KCS WAV completed.');
  Writeln;
  Writeln('Input       : ', InFileName);
  Writeln('Output      : ', OutFileName);
  Writeln('BIN size    : ', DataSize);
  Writeln('H68 size    : ', Length(H68));
  Writeln('Start addr  : $', IntToHex(StartAddress, 4));
  Writeln('Blocks      : ', BlockCount);
  Writeln('WAV samples : ', WavSamples);
  Writeln('WAV time    : ', FormatFloat('0.000', WavSamples / FRAME_RATE), ' sec');
end;

begin
  Writeln('Bin2WAV');
  Writeln('H68/TR BIN -> H68 tape format -> KCS WAV');
  Writeln;

  if ParamCount <> 3 then
  begin
    Writeln('Usage:');
    Writeln('  Bin2WAV input.bin output.wav address');
    Writeln;
    Writeln('Example:');
    Writeln('  Bin2WAV TEST.BIN TEST.WAV F000');
    Writeln;
    Writeln('The program performs both conversions in memory:');
    Writeln('  BIN -> H68/TR format -> KCS 9600Hz 8-bit mono WAV');
    Halt(1);
  end;

  try
    Convert(
      ParamStr(1),
      ParamStr(2),
      HexToWord(ParamStr(3)));
  except
    on E: Exception do
    begin
      Writeln('ERROR: ', E.Message);
      Halt(1);
    end;
  end;
end.

