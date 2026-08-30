program WAV2BIN;

{$APPTYPE CONSOLE}

uses
  SysUtils,
  Classes;

const
  EXPECTED_SAMPLE_RATE = 9600;
  EXPECTED_CHANNELS    = 1;
  EXPECTED_BITS        = 8;

  { KCS:
      2400Hz = 1
      1200Hz = 0

    At 9600Hz:
      1 bit = 32 samples
      1 = 16 transitions
      0 = 8 transitions
  }
  BASE_FREQ = 2400;

  { H68/TR tape format }
  LEADER_COUNT    = 680;
  SEPARATOR_COUNT = 25;
  MARK_B          = $42;
  MARK_G          = $47;

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


{ ================================================================== }
{ WAV decoder                                                        }
{ ================================================================== }

function ReadWordLE(Stream: TStream): Word;
begin
  Stream.ReadBuffer(Result, 2);
end;


function ReadDWordLE(Stream: TStream): Cardinal;
begin
  Stream.ReadBuffer(Result, 4);
end;


function FourCC(const S: AnsiString): Cardinal;
begin
  Result :=
    Ord(S[1]) or
    (Ord(S[2]) shl 8) or
    (Ord(S[3]) shl 16) or
    (Ord(S[4]) shl 24);
end;


function ReadWavHeader(
  Stream: TFileStream;
  out SampleRate: Cardinal;
  out Channels: Word;
  out BitsPerSample: Word;
  out DataOffset: Int64;
  out DataSize: Cardinal): Boolean;
var
  RIFF: Cardinal;
  WAVE: Cardinal;
  ChunkID: Cardinal;
  ChunkSize: Cardinal;
  AudioFormat: Word;
  FmtSize: Cardinal;
begin
  Result := False;
  SampleRate := 0;
  Channels := 0;
  BitsPerSample := 0;
  DataOffset := 0;
  DataSize := 0;

  Stream.Position := 0;

  if Stream.Size < 12 then
    Exit;

  RIFF := ReadDWordLE(Stream);
  if RIFF <> FourCC('RIFF') then
    Exit;

  ReadDWordLE(Stream);

  WAVE := ReadDWordLE(Stream);
  if WAVE <> FourCC('WAVE') then
    Exit;

  while Stream.Position + 8 <= Stream.Size do
  begin
    ChunkID := ReadDWordLE(Stream);
    ChunkSize := ReadDWordLE(Stream);

    if Stream.Position + ChunkSize > Stream.Size then
      Exit;

    if ChunkID = FourCC('fmt ') then
    begin
      FmtSize := ChunkSize;

      if FmtSize < 16 then
        Exit;

      AudioFormat := ReadWordLE(Stream);
      Channels := ReadWordLE(Stream);
      SampleRate := ReadDWordLE(Stream);

      ReadDWordLE(Stream);  { ByteRate }
      ReadWordLE(Stream);   { BlockAlign }
      BitsPerSample := ReadWordLE(Stream);

      if FmtSize > 16 then
        Stream.Seek(FmtSize - 16, soCurrent);

      if AudioFormat <> 1 then
      begin
        Writeln('ERROR: WAV is not PCM.');
        Exit;
      end;
    end
    else
    if ChunkID = FourCC('data') then
    begin
      DataOffset := Stream.Position;
      DataSize := ChunkSize;
      Result := True;
      Exit;
    end
    else
      Stream.Seek(ChunkSize, soCurrent);

    if (ChunkSize and 1) <> 0 then
      Stream.Seek(1, soCurrent);
  end;
end;


function GetSignBit(Sample: Byte): Integer;
begin
  if Sample >= 128 then
    Result := 1
  else
    Result := 0;
end;


function CountTransitions(
  const Data: TByteArray;
  StartPos: Integer;
  Count: Integer): Integer;
var
  I: Integer;
  Previous: Integer;
  Current: Integer;
begin
  Result := 0;

  if Count <= 0 then
    Exit;

  if StartPos < 0 then
    Exit;

  if StartPos + Count > Length(Data) then
    Exit;

  Previous := GetSignBit(Data[StartPos]);

  for I := 1 to Count - 1 do
  begin
    Current := GetSignBit(Data[StartPos + I]);

    if Current <> Previous then
      Inc(Result);

    Previous := Current;
  end;
end;


function DecodeBit(
  const Data: TByteArray;
  StartPos: Integer;
  FramesPerBit: Integer): Integer;
var
  Changes: Integer;
begin
  Changes :=
    CountTransitions(
      Data,
      StartPos,
      FramesPerBit);

  if Changes >= 12 then
    Result := 1
  else
    Result := 0;
end;


function IsStartBit(
  const Data: TByteArray;
  StartPos: Integer;
  FramesPerBit: Integer): Boolean;
var
  Changes: Integer;
begin
  Changes :=
    CountTransitions(
      Data,
      StartPos,
      FramesPerBit);

  Result := Changes <= 10;
end;


function IsStopBit(
  const Data: TByteArray;
  StartPos: Integer;
  FramesPerBit: Integer): Boolean;
var
  Changes: Integer;
begin
  Changes :=
    CountTransitions(
      Data,
      StartPos,
      FramesPerBit);

  Result := Changes >= 12;
end;


function DecodeByte(
  const Data: TByteArray;
  StartPos: Integer;
  FramesPerBit: Integer;
  out ByteValue: Byte): Boolean;
var
  BitNo: Integer;
  Value: Byte;
  StartChanges: Integer;
  Stop1Pos: Integer;
  Stop2Pos: Integer;
begin
  Result := False;
  ByteValue := 0;

  StartChanges :=
    CountTransitions(
      Data,
      StartPos,
      FramesPerBit);

  if StartChanges > 10 then
    Exit;

  Value := 0;

  { 8 data bits, LSB first }
  for BitNo := 0 to 7 do
  begin
    if DecodeBit(
         Data,
         StartPos +
         FramesPerBit +
         BitNo * FramesPerBit,
         FramesPerBit) <> 0 then
      Value :=
        Value or
        (Byte(1) shl BitNo);
  end;

  Stop1Pos :=
    StartPos +
    FramesPerBit * 9;

  if not IsStopBit(
           Data,
           Stop1Pos,
           FramesPerBit) then
    Exit;

  Stop2Pos :=
    StartPos +
    FramesPerBit * 10;

  if not IsStopBit(
           Data,
           Stop2Pos,
           FramesPerBit) then
    Exit;

  ByteValue := Value;
  Result := True;
end;


function FindStartBit(
  const Data: TByteArray;
  SearchStart: Integer;
  FramesPerBit: Integer): Integer;
var
  P: Integer;
  B: Byte;
begin
  Result := -1;
  P := SearchStart;

  while P + FramesPerBit * 11 <= Length(Data) do
  begin
    if IsStartBit(Data, P, FramesPerBit) then
    begin
      if DecodeByte(Data, P, FramesPerBit, B) then
      begin
        Result := P;
        Exit;
      end;
    end;

    Inc(P);
  end;
end;


procedure DecodeWavToH68(
  const InputFileName: string;
  out H68: TByteArray);
var
  WavFile: TFileStream;
  SampleRate: Cardinal;
  Channels: Word;
  BitsPerSample: Word;
  DataOffset: Int64;
  DataSize: Cardinal;
  Audio: TByteArray;
  FramesPerBit: Integer;
  Pos: Integer;
  ByteValue: Byte;
  Count: Cardinal;
begin
  H68 := nil;

  WavFile :=
    TFileStream.Create(
      InputFileName,
      fmOpenRead or fmShareDenyWrite);
  try
    if not ReadWavHeader(
             WavFile,
             SampleRate,
             Channels,
             BitsPerSample,
             DataOffset,
             DataSize) then
      raise Exception.Create('Invalid WAV file.');

    Writeln('WAV information:');
    Writeln('  Sample rate : ', SampleRate, ' Hz');
    Writeln('  Channels    : ', Channels);
    Writeln('  Bits/sample : ', BitsPerSample);
    Writeln('  Data size   : ', DataSize, ' bytes');
    Writeln;

    if Channels <> EXPECTED_CHANNELS then
      raise Exception.Create('Only mono WAV is supported.');

    if BitsPerSample <> EXPECTED_BITS then
      raise Exception.Create('Only 8-bit PCM WAV is supported.');

    if SampleRate <> EXPECTED_SAMPLE_RATE then
      Writeln('WARNING: WAV sample rate is not 9600 Hz.');

    { One KCS bit is 8 cycles of 2400Hz = 32 samples at 9600Hz.
      For other sample rates, calculate the corresponding length. }
    FramesPerBit :=
      Round(SampleRate * 8 / BASE_FREQ);

    if FramesPerBit < 1 then
      raise Exception.Create('Invalid WAV sample rate.');

    Writeln('  Frames/bit : ', FramesPerBit);
    Writeln;

    if Int64(DataSize) > MaxInt then
      raise Exception.Create('WAV data is too large.');

    WavFile.Position := DataOffset;

    SetLength(Audio, Integer(DataSize));

    if DataSize > 0 then
      WavFile.ReadBuffer(Audio[0], DataSize);

  finally
    WavFile.Free;
  end;

  Pos := 0;
  Count := 0;

  while True do
  begin
    Pos :=
      FindStartBit(
        Audio,
        Pos,
        FramesPerBit);

    if Pos < 0 then
      Break;

    if DecodeByte(
         Audio,
         Pos,
         FramesPerBit,
         ByteValue) then
    begin
      AppendByte(H68, ByteValue);
      Inc(Count);

      { START + 8 DATA + 2 STOP = 11 bits }
      Inc(Pos, FramesPerBit * 11);
    end
    else
      Inc(Pos);
  end;

  Writeln('KCS decoded bytes: ', Count);
end;


{ ================================================================== }
{ H68/TR decoder                                                      }
{ ================================================================== }

function ReadByteFromArray(
  const Data: TByteArray;
  var Pos: Integer): Byte;
begin
  if (Pos < 0) or (Pos >= Length(Data)) then
    raise Exception.Create('Unexpected end of H68 data.');

  Result := Data[Pos];
  Inc(Pos);
end;


procedure CheckFFArray(
  const Data: TByteArray;
  var Pos: Integer;
  Count: Integer;
  const Name: string);
var
  I: Integer;
  B: Byte;
begin
  for I := 1 to Count do
  begin
    B := ReadByteFromArray(Data, Pos);

    if B <> $FF then
      raise Exception.CreateFmt(
        '%s: expected FF at position %d, got $%s.',
        [Name, I, IntToHex(B, 2)]);
  end;
end;


function ReadWordBEArray(
  const Data: TByteArray;
  var Pos: Integer): Word;
var
  H, L: Byte;
begin
  H := ReadByteFromArray(Data, Pos);
  L := ReadByteFromArray(Data, Pos);

  Result :=
    (Word(H) shl 8) or Word(L);
end;


procedure ConvertH68ToBIN(
  const H68: TByteArray;
  const OutFileName: string);
var
  OutFile: TFileStream;
  Pos: Integer;
  Marker: Byte;
  LengthByte: Byte;
  BlockSize: Integer;
  Address: Word;
  ExpectedAddress: Word;
  BlockNo: Integer;
  FirstBlock: Boolean;
  I: Integer;
  Data: TByteArray;
begin
  Pos := 0;

  Writeln;
  Writeln('H68/TR decoding:');
  Writeln('  H68 size: ', Length(H68), ' bytes');

  { -------------------------------------------------------------- }
  { First 680 bytes must be FF                                      }
  { -------------------------------------------------------------- }

  CheckFFArray(
    H68,
    Pos,
    LEADER_COUNT,
    'Leader');

  OutFile :=
    TFileStream.Create(
      OutFileName,
      fmCreate);
  try
    FirstBlock := True;
    BlockNo := 0;
    ExpectedAddress := 0;

    while Pos < Length(H68) do
    begin
      Marker := ReadByteFromArray(H68, Pos);

      if Marker = MARK_G then
        Break;

      if Marker <> MARK_B then
        raise Exception.CreateFmt(
          'Expected B ($42) or G ($47), got $%s at H68 offset %d.',
          [IntToHex(Marker, 2), Pos - 1]);

      Inc(BlockNo);

      LengthByte := ReadByteFromArray(H68, Pos);

      { FF means 256 bytes, therefore length = byte + 1 }
      BlockSize := Integer(LengthByte) + 1;

      Address :=
        ReadWordBEArray(
          H68,
          Pos);

      Writeln(
        '  Block ',
        BlockNo,
        ': address=$',
        IntToHex(Address, 4),
        ' length=',
        BlockSize);

      if FirstBlock then
      begin
        ExpectedAddress := Address;
        FirstBlock := False;
      end;

      if Address <> ExpectedAddress then
      begin
        Writeln('    WARNING: non-contiguous address.');
        Writeln('      Expected $', IntToHex(ExpectedAddress, 4));
        Writeln('      Actual   $', IntToHex(Address, 4));
      end;

      if Pos + BlockSize + SEPARATOR_COUNT > Length(H68) then
        raise Exception.Create('Unexpected end of H68 block.');

      SetLength(Data, BlockSize);

      for I := 0 to BlockSize - 1 do
        Data[I] :=
          ReadByteFromArray(H68, Pos);

      OutFile.WriteBuffer(
        Data[0],
        BlockSize);

      Inc(ExpectedAddress, BlockSize);

      CheckFFArray(
        H68,
        Pos,
        SEPARATOR_COUNT,
        'Block separator');
    end;

    if Marker <> MARK_G then
      raise Exception.Create('End marker G was not found.');

  finally
    OutFile.Free;
  end;

  Writeln;
  Writeln('WAV -> H68 -> BIN completed.');
  Writeln('Blocks: ', BlockNo);
end;


{ ================================================================== }
{ Main                                                               }
{ ================================================================== }

var
  H68: TByteArray;
begin
  Writeln('WAV2BIN');
  Writeln('KCS WAV -> H68/TR -> BIN converter');
  Writeln;

  if ParamCount <> 2 then
  begin
    Writeln('Usage:');
    Writeln('  WAV2BIN input.wav output.bin');
    Writeln;
    Writeln('Example:');
    Writeln('  WAV2BIN TEST.WAV TEST.BIN');
    Writeln;
    Halt(1);
  end;

  try
    DecodeWavToH68(
      ParamStr(1),
      H68);

    ConvertH68ToBIN(
      H68,
      ParamStr(2));

  except
    on E: Exception do
    begin
      Writeln;
      Writeln('ERROR: ', E.Message);
      Halt(1);
    end;
  end;
end.

