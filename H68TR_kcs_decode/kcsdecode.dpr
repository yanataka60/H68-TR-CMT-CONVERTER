program kcsdecode;

{$APPTYPE CONSOLE}

uses
  Windows,
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
      1 = 16 sign changes
      0 = 8 sign changes
  }

  BASE_FREQ = 2400;

type
  TByteArray = array of Byte;


{ ------------------------------------------------------------------ }
{ Little endian WAV reading                                           }
{ ------------------------------------------------------------------ }

function ReadWordLE(Stream: TStream): Word;
begin
  Stream.ReadBuffer(Result, 2);
end;


function ReadDWordLE(Stream: TStream): Cardinal;
begin
  Stream.ReadBuffer(Result, 4);
end;


function FourCC(
  const S: AnsiString): Cardinal;
begin
  Result :=
    Ord(S[1]) or
    (Ord(S[2]) shl 8) or
    (Ord(S[3]) shl 16) or
    (Ord(S[4]) shl 24);
end;


{ ------------------------------------------------------------------ }
{ WAV header                                                           }
{ ------------------------------------------------------------------ }

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

  { RIFF }
  RIFF := ReadDWordLE(Stream);

  if RIFF <> FourCC('RIFF') then
    Exit;

  { RIFF size }
  ReadDWordLE(Stream);

  { WAVE }
  WAVE := ReadDWordLE(Stream);

  if WAVE <> FourCC('WAVE') then
    Exit;

  while Stream.Position + 8 <= Stream.Size do
  begin
    ChunkID := ReadDWordLE(Stream);
    ChunkSize := ReadDWordLE(Stream);

    if ChunkID = FourCC('fmt ') then
    begin
      FmtSize := ChunkSize;

      AudioFormat := ReadWordLE(Stream);
      Channels := ReadWordLE(Stream);
      SampleRate := ReadDWordLE(Stream);

      { ByteRate }
      ReadDWordLE(Stream);

      { BlockAlign }
      ReadWordLE(Stream);

      BitsPerSample := ReadWordLE(Stream);

      if FmtSize > 16 then
        Stream.Seek(FmtSize - 16, soCurrent);

      if AudioFormat <> 1 then
      begin
        Writeln('ERROR: WAV is not PCM.');
        Exit;
      end;
    end

    else if ChunkID = FourCC('data') then
    begin
      DataOffset := Stream.Position;
      DataSize := ChunkSize;

      Result := True;
      Exit;
    end

    else
      Stream.Seek(ChunkSize, soCurrent);

    { WAV chunks are word aligned }
    if (ChunkSize and 1) <> 0 then
      Stream.Seek(1, soCurrent);
  end;
end;


{ ------------------------------------------------------------------ }
{ Convert sample to sign bit                                           }
{ ------------------------------------------------------------------ }

function GetSignBit(
  Sample: Byte): Integer;
begin
  if Sample >= 128 then
    Result := 1
  else
    Result := 0;
end;


{ ------------------------------------------------------------------ }
{ Count sign changes                                                   }
{ ------------------------------------------------------------------ }

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


{ ------------------------------------------------------------------ }
{ Determine whether a 32-sample period is a KCS 0 or 1                 }
{ ------------------------------------------------------------------ }

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

  { 1200Hz:
       8 transitions

    2400Hz:
      16 transitions

    Threshold:
       12
  }

  if Changes >= 12 then
    Result := 1
  else
    Result := 0;
end;


{ ------------------------------------------------------------------ }
{ Check whether candidate position looks like a START bit              }
{ ------------------------------------------------------------------ }

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

  { START = KCS zero = approximately 8 transitions }

  Result := Changes <= 10;
end;


{ ------------------------------------------------------------------ }
{ Check STOP bits                                                       }
{ ------------------------------------------------------------------ }

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

  { STOP = KCS one = approximately 16 transitions }

  Result := Changes >= 12;
end;


{ ------------------------------------------------------------------ }
{ Decode one byte                                                       }
{ ------------------------------------------------------------------ }

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

  { START }
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
    begin
      Value :=
        Value or
        (Byte(1) shl BitNo);
    end;
  end;

  { STOP bit 1 }
  Stop1Pos :=
    StartPos +
    FramesPerBit * 9;

  if not IsStopBit(
           Data,
           Stop1Pos,
           FramesPerBit) then
    Exit;

  { STOP bit 2 }
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


{ ------------------------------------------------------------------ }
{ Search for next START bit                                            }
{ ------------------------------------------------------------------ }

function FindStartBit(
  const Data: TByteArray;
  SearchStart: Integer;
  FramesPerBit: Integer): Integer;

var
  P: Integer;
  B: Byte;

begin
  Result := -1;

  { Need enough room for:
      start + 8 data + 2 stop
      = 11 bits
  }

  P := SearchStart;

  while P +
        FramesPerBit * 11 <=
        Length(Data) do
  begin
    if IsStartBit(
         Data,
         P,
         FramesPerBit) then
    begin
      { Validate the entire byte.
        This avoids false detection in the leader. }

      if DecodeByte(
           Data,
           P,
           FramesPerBit,
           B) then
      begin
        Result := P;
        Exit;
      end;
    end;

    Inc(P);
  end;
end;


{ ------------------------------------------------------------------ }
{ Decode complete WAV                                                   }
{ ------------------------------------------------------------------ }

procedure DecodeWav(
  const InputFileName: string;
  const OutputFileName: string);

var
  WavFile: TFileStream;
  OutFile: TFileStream;

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
    begin
      raise Exception.Create(
        'Invalid WAV file.');
    end;

    Writeln('WAV information:');
    Writeln('  Sample rate : ', SampleRate, ' Hz');
    Writeln('  Channels    : ', Channels);
    Writeln('  Bits/sample : ', BitsPerSample);
    Writeln('  Data size   : ', DataSize, ' bytes');
    Writeln;

    if Channels <> 1 then
      raise Exception.Create(
        'Only mono WAV is supported.');

    if BitsPerSample <> 8 then
      raise Exception.Create(
        'Only 8-bit PCM WAV is supported.');

    if SampleRate <> EXPECTED_SAMPLE_RATE then
      Writeln(
        'WARNING: sample rate is not 9600 Hz.');

    FramesPerBit :=
      Round(
        SampleRate * 8 /
        BASE_FREQ);

    Writeln(
      'Frames per bit: ',
      FramesPerBit);

    WavFile.Position := DataOffset;

    SetLength(Audio, DataSize);

    if DataSize > 0 then
      WavFile.ReadBuffer(
        Audio[0],
        DataSize);

  finally
    WavFile.Free;
  end;


  OutFile :=
    TFileStream.Create(
      OutputFileName,
      fmCreate);

  try

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
        { IMPORTANT:
            Write EVERY byte.

            00 is NOT discarded.
            0D is NOT discarded.
            FF is NOT discarded.
        }

        OutFile.WriteBuffer(
          ByteValue,
          1);

        Inc(Count);

        { Advance exactly 11 bits:
            START
            8 DATA
            STOP
            STOP
        }

        Inc(
          Pos,
          FramesPerBit * 11);
      end
      else
        Inc(Pos);
    end;

    Writeln(
      'Decoded bytes: ',
      Count);

  finally
    OutFile.Free;
  end;
end;


{ ------------------------------------------------------------------ }
{ Main                                                                 }
{ ------------------------------------------------------------------ }

begin

  Writeln('KCSDECODE - Binary KCS decoder');
  Writeln('Delphi 7 compatible');
  Writeln;

  if ParamCount <> 2 then
  begin
    Writeln(
      'Usage: KCSDECODE input.wav output.bin');
    Writeln;
    Halt(1);
  end;

  try

    DecodeWav(
      ParamStr(1),
      ParamStr(2));

    Writeln;
    Writeln('KCS decoding completed.');

  except

    on E: Exception do
    begin
      Writeln;
      Writeln('ERROR: ', E.Message);
      Halt(1);
    end;

  end;
end.
