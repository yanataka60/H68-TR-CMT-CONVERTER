program SMC70CmtRawDecode;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.Math;

type
  TSampleArray = array of Integer;

  TRun = record
    Level: Byte;
    Count: Integer;
  end;

  TRunArray = array of TRun;

  TByteArray = TBytes;

  TWavInfo = record
    SampleRate: Cardinal;
    Channels: Word;
    BitsPerSample: Word;
    Samples: TSampleArray;
  end;

  TLabelInfo = record
    FileID: Byte;
    FileName: string;
    FileType: string;

    LoadAddress: Word;
    ExecuteAddress: Word;
    DataLength: Word;
    CommandFlag: Word;

    Checksum: Byte;
  end;


function ReadU16LE(
  const B: TBytes;
  P: Integer
): Word;
begin
  Result :=
    Word(B[P]) or
    (Word(B[P + 1]) shl 8);
end;


function ReadU32LE(
  const B: TBytes;
  P: Integer
): Cardinal;
begin
  Result :=
    Cardinal(B[P]) or
    (Cardinal(B[P + 1]) shl 8) or
    (Cardinal(B[P + 2]) shl 16) or
    (Cardinal(B[P + 3]) shl 24);
end;


function FourCC(
  const B: TBytes;
  P: Integer
): string;
begin
  SetString(
    Result,
    PAnsiChar(@B[P]),
    4
  );
end;


procedure LoadWav(
  const FileName: string;
  out W: TWavInfo
);
var
  F: TFileStream;
  B: TBytes;

  P: Integer;
  ChunkSize: Cardinal;
  ChunkID: string;

  AudioFormat: Word;
  Channels: Word;
  SampleRate: Cardinal;
  Bits: Word;

  DataPos: Integer;
  DataSize: Cardinal;

  I: Integer;
  V: SmallInt;

begin
  FillChar(W, SizeOf(W), 0);

  F :=
    TFileStream.Create(
      FileName,
      fmOpenRead or fmShareDenyWrite
    );

  try

    SetLength(B, F.Size);

    if F.Size > 0 then
      F.ReadBuffer(B[0], F.Size);

  finally
    F.Free;
  end;


  if Length(B) < 12 then
    raise Exception.Create(
      'WAVファイルが小さすぎます。'
    );


  if FourCC(B, 0) <> 'RIFF' then
    raise Exception.Create(
      'RIFFではありません。'
    );


  if FourCC(B, 8) <> 'WAVE' then
    raise Exception.Create(
      'WAVEではありません。'
    );


  AudioFormat := 0;
  Channels := 0;
  SampleRate := 0;
  Bits := 0;

  DataPos := -1;
  DataSize := 0;

  P := 12;


  while P + 8 <= Length(B) do
  begin

    ChunkID := FourCC(B, P);

    ChunkSize :=
      ReadU32LE(
        B,
        P + 4
      );

    Inc(P, 8);


    if P + Integer(ChunkSize) >
       Length(B) then
      Break;


    if ChunkID = 'fmt ' then
    begin

      if ChunkSize < 16 then
        raise Exception.Create(
          'fmtチャンクが不正です。'
        );

      AudioFormat :=
        ReadU16LE(B, P);

      Channels :=
        ReadU16LE(B, P + 2);

      SampleRate :=
        ReadU32LE(B, P + 4);

      Bits :=
        ReadU16LE(B, P + 14);

    end
    else
    if ChunkID = 'data' then
    begin

      DataPos := P;
      DataSize := ChunkSize;

      Break;

    end;


    Inc(P, ChunkSize);

    if Odd(ChunkSize) then
      Inc(P);

  end;


  if AudioFormat <> 1 then
    raise Exception.Create(
      'PCM形式ではありません。'
    );


  if Channels <> 1 then
    raise Exception.Create(
      'モノラルWAVを使用してください。'
    );


  if DataPos < 0 then
    raise Exception.Create(
      'dataチャンクがありません。'
    );


  if not (Bits in [8, 16]) then
    raise Exception.Create(
      '8bitまたは16bit PCMのみ対応しています。'
    );


  W.SampleRate := SampleRate;
  W.Channels := Channels;
  W.BitsPerSample := Bits;


  if Bits = 8 then
  begin

    SetLength(
      W.Samples,
      DataSize
    );

    for I := 0 to Integer(DataSize) - 1 do
      W.Samples[I] :=
        Integer(B[DataPos + I]) - 128;

  end
  else
  begin

    SetLength(
      W.Samples,
      DataSize div 2
    );

    for I := 0 to High(W.Samples) do
    begin

      V :=
        SmallInt(
          Word(B[DataPos + I * 2]) or
          (Word(B[DataPos + I * 2 + 1]) shl 8)
        );

      W.Samples[I] := V;

    end;

  end;

end;


function CalculateThreshold(
  const Samples: TSampleArray
): Integer;
var
  MinV: Integer;
  MaxV: Integer;
  I: Integer;

begin
  if Length(Samples) = 0 then
    Exit(0);

  MinV := Samples[0];
  MaxV := Samples[0];

  for I := 1 to High(Samples) do
  begin

    if Samples[I] < MinV then
      MinV := Samples[I];

    if Samples[I] > MaxV then
      MaxV := Samples[I];

  end;

  Result :=
    (MinV + MaxV) div 2;
end;


function MakeRuns(
  const Samples: TSampleArray;
  Threshold: Integer
): TRunArray;
var
  I: Integer;
  Level: Byte;
  LastLevel: Byte;
  Count: Integer;
  N: Integer;

begin
  SetLength(Result, 0);

  if Length(Samples) = 0 then
    Exit;


  if Samples[0] >= Threshold then
    LastLevel := 1
  else
    LastLevel := 0;


  Count := 1;


  for I := 1 to High(Samples) do
  begin

    if Samples[I] >= Threshold then
      Level := 1
    else
      Level := 0;


    if Level = LastLevel then
    begin

      Inc(Count);

    end
    else
    begin

      N := Length(Result);

      SetLength(Result, N + 1);

      Result[N].Level :=
        LastLevel;

      Result[N].Count :=
        Count;


      LastLevel := Level;

      Count := 1;

    end;

  end;


  N := Length(Result);

  SetLength(Result, N + 1);

  Result[N].Level :=
    LastLevel;

  Result[N].Count :=
    Count;

end;


function PairLength(
  const Runs: TRunArray;
  P: Integer
): Integer;
begin
  if P + 1 >= Length(Runs) then
    Exit(-1);

  Result :=
    Runs[P].Count +
    Runs[P + 1].Count;
end;


procedure AnalyzePWM(
  const Runs: TRunArray;
  out ZeroCenter: Double;
  out OneCenter: Double
);
var
  Values: array of Integer;
  I: Integer;
  N: Integer;

  C0: Double;
  C1: Double;

  S0: Double;
  S1: Double;

  N0: Integer;
  N1: Integer;

  V: Integer;
  D0: Double;
  D1: Double;

  K: Integer;

begin
  SetLength(Values, 0);


  for I := 0 to High(Runs) - 1 do
  begin

    if Runs[I].Level <> 1 then
      Continue;

    if Runs[I + 1].Level <> 0 then
      Continue;

    V :=
      PairLength(
        Runs,
        I
      );

    // データPWMとして妥当な範囲だけ使用
    if (V >= 20) and
       (V <= 55) then
    begin

      N := Length(Values);

      SetLength(
        Values,
        N + 1
      );

      Values[N] := V;

    end;

  end;


  if Length(Values) < 100 then
    raise Exception.Create(
      'PWMデータを十分に検出できません。'
    );


  C0 := Values[0];
  C1 := Values[0];


  for I := 1 to High(Values) do
  begin

    if Values[I] < C0 then
      C0 := Values[I];

    if Values[I] > C1 then
      C1 := Values[I];

  end;


  for K := 1 to 20 do
  begin

    S0 := 0;
    S1 := 0;

    N0 := 0;
    N1 := 0;


    for I := 0 to High(Values) do
    begin

      D0 :=
        Abs(
          Values[I] - C0
        );

      D1 :=
        Abs(
          Values[I] - C1
        );


      if D0 <= D1 then
      begin

        S0 := S0 + Values[I];
        Inc(N0);

      end
      else
      begin

        S1 := S1 + Values[I];
        Inc(N1);

      end;

    end;


    if N0 > 0 then
      C0 := S0 / N0;

    if N1 > 0 then
      C1 := S1 / N1;

  end;


  if C0 > C1 then
  begin
    V := Round(C0);
    C0 := C1;
    C1 := V;
  end;


  ZeroCenter := C0;
  OneCenter := C1;

end;


function DecodeByteLoose(
  const Runs: TRunArray;
  StartRun: Integer;
  BitThreshold: Double;
  out Value: Byte
): Boolean;
var
  P: Integer;
  I: Integer;
  Sum: Integer;
  Bit: Integer;
  V: Byte;
begin
  Result := False;
  Value := 0;

  if StartRun + 19 >= Length(Runs) then
    Exit;

  // STARTはSMC-70の1シンボル。
  // 録音ノイズによる極端に短い偽候補を排除する。
  Sum := PairLength(Runs, StartRun);
  if (Sum < 20) or (Sum > 45) then
    Exit;

  P := StartRun + 2;
  V := 0;

  // B7～B0
  // 実機録音ではビット境界付近に数sampleの欠落/分割が
  // 発生する場合があるため、ビット幅はやや広く許容する。
  for I := 7 downto 0 do
  begin
    Sum := PairLength(Runs, P);
    if (Sum < 3) or (Sum > 55) then
      Exit;

    if Sum >= BitThreshold then
      Bit := 1
    else
      Bit := 0;

    if Bit <> 0 then
      V := V or Byte(1 shl I);

    Inc(P, 2);
  end;

  // STOPは厳密判定しない。
  // 実機録音では次シンボルとの境界で結合する場合がある。

  Value := V;
  Result := True;
end;

function DecodeBytes(
  const Runs: TRunArray;
  StartRun: Integer;
  Count: Integer;
  BitThreshold: Double
): TByteArray;
var
  I: Integer;
  P: Integer;
  V: Byte;

begin
  SetLength(
    Result,
    Count
  );

  P := StartRun;


  for I := 0 to Count - 1 do
  begin

    if not DecodeByteLoose(
      Runs,
      P,
      BitThreshold,
      V
    ) then
    begin

      SetLength(
        Result,
        I
      );

      Exit;

    end;


    Result[I] := V;

    Inc(P, 20);

  end;

end;


function XorBytes(
  const Data: TByteArray;
  StartPos: Integer;
  Count: Integer
): Byte;
var
  I: Integer;

begin
  Result := 0;

  for I := 0 to Count - 1 do
    Result :=
      Result xor
      Data[StartPos + I];

end;


function IsPrintableSMCChar(
  B: Byte
): Boolean;
begin
  Result :=
    ((B >= $20) and
     (B <= $7E));
end;


function FindStandardLabel(
  const Runs: TRunArray;
  BitThreshold: Double;
  out LabelRun: Integer;
  out Info: TLabelInfo;
  out RawLabel: TByteArray
): Boolean;
var
  R: Integer;
  D: TByteArray;
  I: Integer;
  V: Byte;

  NameOK: Boolean;
  TypeOK: Boolean;

  Check: Byte;

  S: string;

begin
  Result := False;

  LabelRun := -1;

  FillChar(
    Info,
    SizeOf(Info),
    0
  );

  SetLength(RawLabel, 0);


  for R := 0 to Length(Runs) - 20 * 35 - 1 do
  begin

    // START候補
    if Runs[R].Level <> 1 then
      Continue;


    D :=
      DecodeBytes(
        Runs,
        R,
        35,
        BitThreshold
      );


    if Length(D) <> 35 then
      Continue;


    // File ID
    if D[0] > $0F then
      Continue;


    NameOK := True;

    for I := 1 to 8 do
    begin
      if not IsPrintableSMCChar(D[I]) then
      begin
        NameOK := False;
        Break;
      end;
    end;

    if not NameOK then
      Continue;


    TypeOK := True;

    for I := 9 to 11 do
    begin
      if not IsPrintableSMCChar(D[I]) then
      begin
        TypeOK := False;
        Break;
      end;
    end;

    if not TypeOK then
      Continue;


    Check :=
      XorBytes(
        D,
        0,
        32
      );


    if Check <> D[32] then
      Continue;


    // ファイル名
    S := '';

    for I := 1 to 8 do
      S :=
        S +
        Chr(D[I]);

    Info.FileName :=
      TrimRight(S);


    // タイプ
    S := '';

    for I := 9 to 11 do
      S :=
        S +
        Chr(D[I]);

    Info.FileType :=
      TrimRight(S);


    Info.FileID :=
      D[0];


    // SMC-70標準ラベル
    //
    // D[12] D[13] = 格納番地       (Little Endian)
    // D[14] D[15] = 実行開始番地   (Little Endian)
    // D[16] D[17] = ロード長       (Little Endian)
    //
    // test4.wavでは
    //   00 01 = 0100h
    //   00 01 = 0100h
    //   07 03 = 0307h = 775 bytes
    //
    // D[12]～D[14]を3バイトのアドレスとして扱わない。
    Info.LoadAddress :=
      ReadU16LE(D, 12);

    Info.ExecuteAddress :=
      ReadU16LE(D, 14);

    Info.DataLength :=
      ReadU16LE(D, 16);

    Info.CommandFlag :=
      ReadU16LE(D, 18);

    // 実測したSMC-70標準ラベルでは
    // D[0]～D[31]のXORがD[32]、
    // D[33]とD[34]は00h。
    Info.Checksum :=
      D[32];


    LabelRun := R;
    RawLabel := Copy(D, 0, Length(D));

    Result := True;

    Exit;

  end;

end;


function FindRecordStart(
  const Runs: TRunArray;
  SearchStart: Integer;
  BitThreshold: Double;
  ZeroCenter: Double;
  OneCenter: Double
): Integer;
var
  R: Integer;
  J: Integer;
  V: Integer;

  HeaderThreshold: Double;
  HeaderOK: Boolean;

  DataHeader: Integer;

begin
  Result := -1;


  // 10パルスのリーダーは
  // 0/1データPWMより長い。
  //
  // 今回のWAV:
  // data 0 = 約29～30
  // data 1 = 約39～40
  // leader = 約66～67


  HeaderThreshold :=
    OneCenter * 1.35;


  for R := SearchStart
    to Length(Runs) - 24 do
  begin

    if Runs[R].Level <> 1 then
      Continue;


    HeaderOK := True;


    // 10 pulse
    for J := 0 to 9 do
    begin

      V :=
        PairLength(
          Runs,
          R + J * 2
        );


      if V < HeaderThreshold then
      begin
        HeaderOK := False;
        Break;
      end;

    end;


    if not HeaderOK then
      Continue;


    // 10パルスの直後に
    // 714us相当のheader pulseが1個ある
    DataHeader :=
      R + 20;


    V :=
      PairLength(
        Runs,
        DataHeader
      );


    if (V < 0) or
       (V >= HeaderThreshold) then
      Continue;


    // header pulseの後が
    // 実際のデータ開始
    Result :=
      R + 22;

    Exit;

  end;

end;



function TryDecodeRecordCandidate(
  const Runs: TRunArray;
  StartRun: Integer;
  BitThreshold: Double;
  out RecordData: TByteArray;
  out StoredChecksum: Byte;
  out NonZeroCount: Integer;
  out TimingError: Double
): Boolean;
var
  I: Integer;
  V: Byte;
  Sum: Integer;
  Calc: Byte;
begin
  Result := False;
  SetLength(RecordData, 0);
  StoredChecksum := 0;
  NonZeroCount := 0;
  TimingError := 0.0;

  SetLength(RecordData, 128);

  for I := 0 to 127 do
  begin
    if not DecodeByteLoose(
      Runs,
      StartRun + I * 20,
      BitThreshold,
      V
    ) then
    begin
      SetLength(RecordData, 0);
      Exit;
    end;

    RecordData[I] := V;

    if V <> 0 then
      Inc(NonZeroCount);

    Sum := PairLength(Runs, StartRun + I * 20);
    if Abs(Sum - 29.5) < Abs(Sum - 39.5) then
      TimingError := TimingError + Abs(Sum - 29.5)
    else
      TimingError := TimingError + Abs(Sum - 39.5);
  end;

  if not DecodeByteLoose(
    Runs,
    StartRun + 128 * 20,
    BitThreshold,
    StoredChecksum
  ) then
  begin
    SetLength(RecordData, 0);
    Exit;
  end;

  Sum := PairLength(Runs, StartRun + 128 * 20);
  if Abs(Sum - 29.5) < Abs(Sum - 39.5) then
    TimingError := TimingError + Abs(Sum - 29.5)
  else
    TimingError := TimingError + Abs(Sum - 39.5);

  Calc := XorBytes(RecordData, 0, 128);

  if Calc <> StoredChecksum then
  begin
    SetLength(RecordData, 0);
    Exit;
  end;

  Result := True;
end;


function FindRecordStartFallback(
  const Runs: TRunArray;
  SearchStart: Integer;
  BitThreshold: Double;
  out RecordData: TByteArray;
  out StoredChecksum: Byte
): Integer;
var
  R: Integer;
  CandidateData: TByteArray;
  CandidateChecksum: Byte;
  CandidateNonZero: Integer;
  CandidateError: Double;

  BestNonZero: Integer;
  BestError: Double;
  BestRun: Integer;
  BestData: TByteArray;
  BestChecksum: Byte;

  HaveBest: Boolean;
begin
  Result := -1;
  SetLength(RecordData, 0);
  StoredChecksum := 0;

  BestNonZero := -1;
  BestError := 1.0E30;
  BestRun := -1;
  BestChecksum := 0;
  SetLength(BestData, 0);
  HaveBest := False;

  // 録音系によってレコード直前のリーダーが崩れる場合があるため、
  // リーダー10組を必須条件とせず、128byte+checksumを直接検証する。
  // 長いZERO領域も候補になるので、非ZERO数を優先し、
  // 同数ならシンボルタイミングの良い候補を採用する。

  for R := SearchStart to Length(Runs) - 20 * 129 do
  begin
    if Runs[R].Level <> 1 then
      Continue;

    if not TryDecodeRecordCandidate(
      Runs,
      R,
      BitThreshold,
      CandidateData,
      CandidateChecksum,
      CandidateNonZero,
      CandidateError
    ) then
      Continue;

    if (not HaveBest) or
       (CandidateNonZero > BestNonZero) or
       ((CandidateNonZero = BestNonZero) and
        (CandidateError < BestError)) then
    begin
      HaveBest := True;
      BestNonZero := CandidateNonZero;
      BestError := CandidateError;
      BestRun := R;
      BestChecksum := CandidateChecksum;
      BestData := Copy(CandidateData, 0, Length(CandidateData));
    end;
  end;

  if HaveBest then
  begin
    Result := BestRun;
    RecordData := BestData;
    StoredChecksum := BestChecksum;
  end;
end;


function FindRecordStartRobust(
  const Runs: TRunArray;
  SearchStart: Integer;
  BitThreshold: Double;
  ZeroCenter: Double;
  OneCenter: Double;
  out RecordData: TByteArray;
  out StoredChecksum: Byte
): Integer;
var
  R: Integer;
  CandidateNonZero: Integer;
  CandidateError: Double;
begin
  SetLength(RecordData, 0);
  StoredChecksum := 0;

  // まず従来方式を試す。従来方式で成功するWAVの動作は維持する。
  R := FindRecordStart(
    Runs,
    SearchStart,
    BitThreshold,
    ZeroCenter,
    OneCenter
  );

  if R >= 0 then
  begin
    if TryDecodeRecordCandidate(
      Runs,
      R,
      BitThreshold,
      RecordData,
      StoredChecksum,
      CandidateNonZero,
      CandidateError
    ) then
      Exit(R);
  end;

  // 従来方式で見つからない場合のみ実機録音向け探索を行う。
  Result := FindRecordStartFallback(
    Runs,
    SearchStart,
    BitThreshold,
    RecordData,
    StoredChecksum
  );
end;

procedure WriteBinary(
  const FileName: string;
  const Data: TByteArray
);
var
  F: TFileStream;
begin
  F :=
    TFileStream.Create(
      FileName,
      fmCreate
    );
  try
    if Length(Data) > 0 then
      F.WriteBuffer(
        Data[0],
        Length(Data)
      );
  finally
    F.Free;
  end;
end;

procedure DecodeSMC70(
  const WavFile: string;
  const OutFile: string
);
var
  W: TWavInfo;

  Runs: TRunArray;

  Threshold: Integer;

  ZeroCenter: Double;
  OneCenter: Double;

  BitThreshold: Double;

  LabelRun: Integer;
  Info: TLabelInfo;
  RawLabel: TByteArray;
  RawOutput: TByteArray;

  RecordStart: Integer;
  ChecksumStart: Integer;

  Remaining: Integer;
  BlockSize: Integer;
  RecordNo: Integer;

  RecordData: TByteArray;

  StoredChecksum: Byte;
  CalculatedChecksum: Byte;

  I: Integer;

begin
  Writeln;
  Writeln(
    'SMC-70 CMT WAV Decoder'
  );
  Writeln(
    '======================'
  );
  Writeln;


  // ------------------------------------------------------------
  // WAV
  // ------------------------------------------------------------

  LoadWav(
    WavFile,
    W
  );


  Writeln(
    'WAV file      : ',
    WavFile
  );

  Writeln(
    'Sample rate   : ',
    W.SampleRate,
    ' Hz'
  );

  Writeln(
    'Channels      : ',
    W.Channels
  );

  Writeln(
    'Bits/sample   : ',
    W.BitsPerSample
  );

  Writeln(
    'Samples       : ',
    Length(W.Samples)
  );


  // ------------------------------------------------------------
  // 波形を0/1 runへ変換
  // ------------------------------------------------------------

  Threshold :=
    CalculateThreshold(
      W.Samples
    );


  Writeln(
    'Wave threshold: ',
    Threshold
  );


  Runs :=
    MakeRuns(
      W.Samples,
      Threshold
    );


  Writeln(
    'Run count     : ',
    Length(Runs)
  );


  // ------------------------------------------------------------
  // PWM 0/1幅を自動解析
  // ------------------------------------------------------------

  AnalyzePWM(
    Runs,
    ZeroCenter,
    OneCenter
  );


  BitThreshold :=
    (ZeroCenter + OneCenter) / 2;


  Writeln;
  Writeln(
    'PWM analysis'
  );

  Writeln(
    '  0 center    : ',
    FormatFloat(
      '0.00',
      ZeroCenter
    ),
    ' samples'
  );

  Writeln(
    '  1 center    : ',
    FormatFloat(
      '0.00',
      OneCenter
    ),
    ' samples'
  );

  Writeln(
    '  threshold   : ',
    FormatFloat(
      '0.00',
      BitThreshold
    ),
    ' samples'
  );


  Writeln;
  Writeln(
    '0 time approx : ',
    FormatFloat(
      '0.0',
      ZeroCenter /
      W.SampleRate *
      1000000
    ),
    ' us'
  );

  Writeln(
    '1 time approx : ',
    FormatFloat(
      '0.0',
      OneCenter /
      W.SampleRate *
      1000000
    ),
    ' us'
  );


  // ------------------------------------------------------------
  // 標準ラベル検索
  // ------------------------------------------------------------

  Writeln;
  Writeln(
    'Searching standard label...'
  );


  if not FindStandardLabel(
    Runs,
    BitThreshold,
    LabelRun,
    Info,
    RawLabel
  ) then
    raise Exception.Create(
      '標準ラベルが見つかりません。'
    );


  Writeln(
    'Label run     : ',
    LabelRun
  );


  Writeln;
  Writeln(
    'Standard Label'
  );

  Writeln(
    '  File ID     : ',
    IntToHex(
      Info.FileID,
      2
    )
  );

  Writeln(
    '  File name   : ',
    Info.FileName
  );

  Writeln(
    '  File type   : ',
    Info.FileType
  );

  Writeln(
    '  Load        : ',
    IntToHex(
      Info.LoadAddress,
      6
    )
  );

  Writeln(
    '  Execute     : ',
    IntToHex(
      Info.ExecuteAddress,
      4
    )
  );

  Writeln(
    '  Data length : ',
    IntToHex(
      Info.DataLength,
      4
    ),
    'h (',
    Info.DataLength,
    ' bytes)'
  );

  Writeln(
    '  Command     : ',
    IntToHex(
      Info.CommandFlag,
      4
    )
  );

  Writeln(
    '  Checksum    : ',
    IntToHex(
      Info.Checksum,
      2
    )
  );


  // ------------------------------------------------------------
  // ラベル後からレコードを探索
  // ------------------------------------------------------------

  Remaining :=
    Info.DataLength;


  RawOutput := Copy(RawLabel, 0, Length(RawLabel));


  RecordStart :=
    FindRecordStartRobust(
      Runs,
      LabelRun + 35 * 20,
      BitThreshold,
      ZeroCenter,
      OneCenter,
      RecordData,
      StoredChecksum
    );


  if RecordStart < 0 then
    raise Exception.Create(
      'Record 1が見つかりません。'
    );


  RecordNo := 0;

  while Remaining > 0 do
  begin

    Inc(RecordNo);


    // ----------------------------------------------------------
    // SMC-70のテープ上のレコードは常に128バイト固定。
    // 最終レコードで実データが128バイト未満でも、
    // WAVには00hで埋めた128バイト全体が記録されている。
    // ----------------------------------------------------------

    BlockSize :=
      Min(
        128,
        Remaining
      );

    RecordData :=
      DecodeBytes(
        Runs,
        RecordStart,
        128,
        BitThreshold
      );


    if Length(RecordData) <> 128 then
      raise Exception.CreateFmt(
        'Record %dの128バイトデータを完全に復号できません。',
        [RecordNo]
      );


    // ----------------------------------------------------------
    // RAW CMT出力
    // ----------------------------------------------------------
    // スタンダードラベルの後に、テープ上の各レコードを
    // 「128バイトのデータ + 1バイトのチェックサム」
    // のまま追加する。
    // 最終レコードの00hパディングもテープ上に存在するため
    // 省略せず、そのまま出力する。
    I := Length(RawOutput);
    SetLength(RawOutput, I + 129);
    Move(RecordData[0], RawOutput[I], 128);


    // ----------------------------------------------------------
    // チェックサム
    // ----------------------------------------------------------
    // チェックサムはテープ上の128バイト全体から計算する。

    ChecksumStart :=
      RecordStart +
      128 * 20;


    if not DecodeByteLoose(
      Runs,
      ChecksumStart,
      BitThreshold,
      StoredChecksum
    ) then
      raise Exception.CreateFmt(
        'Record %dのチェックサムを復号できません。',
        [RecordNo]
      );


    CalculatedChecksum :=
      XorBytes(
        RecordData,
        0,
        128
      );

    if CalculatedChecksum =
       StoredChecksum then
    begin

    end
    else
    begin

      Writeln(
        '  Checksum            : ERROR'
      );

      raise Exception.CreateFmt(
        'Record %dのチェックサムエラー。',
        [RecordNo]
      );

    end;

    // レコード末尾のチェックサムもテープ上の値をそのまま保存する。
    RawOutput[I + 128] := StoredChecksum;

    Dec(
      Remaining,
      BlockSize
    );



    if Remaining > 0 then
    begin

      RecordStart :=
        FindRecordStartRobust(
          Runs,
          ChecksumStart + 20,
          BitThreshold,
          ZeroCenter,
          OneCenter,
          RecordData,
          StoredChecksum
        );


      if RecordStart < 0 then
        raise Exception.CreateFmt(
          'Record %dの次のレコードが見つかりません。',
          [RecordNo + 1]
        );

    end;

  end;


  // ------------------------------------------------------------
  // RAW CMT全データをそのまま出力
  // ------------------------------------------------------------
  //
  // 出力形式:
  //   35 bytes : Standard Label
  //   129 bytes: Record 1 (128 data + 1 checksum)
  //   129 bytes: Record 2 (128 data + 1 checksum)
  //   ...
  //
  // 最終レコードも128バイト固定で、実データが短い場合の
  // 00hパディングを含めて出力する。
  // リーダー、START/STOPビット、レコードヘッダ、無音部は
  // バイナリ出力には含めない。

  WriteBinary(
    OutFile,
    RawOutput
  );


  Writeln;
  Writeln(
    'RAW output file : ',
    OutFile
  );

  Writeln(
    'RAW output size : ',
    Length(RawOutput),
    ' bytes'
  );

  Writeln(
    'Standard Label  : 35 bytes'
  );

  Writeln(
    'Records         : ',
    RecordNo
  );

  Writeln(
    'Each record     : 128 data + 1 checksum = 129 bytes'
  );


  Writeln;
  Writeln(
    'RAW decode completed successfully.'
  );

end;


procedure ShowUsage;
begin

  Writeln(
    'SMC70CmtRawDecode.exe input.wav output.bin'
  );

  Writeln;
  Writeln(
    'SMC-70 CMTのRAW論理データを出力:'
  );

  Writeln(
    '  SMC70CmtRawDecode.exe test4.wav test4.raw.bin'
  );

  Writeln;
  Writeln(
    '入力WAVからスタンダードラベルと各レコードを復号し、'
  );

  Writeln(
    'テープ上の論理バイナリ順序のままoutput.binへ出力します。'
  );

end;


var
  WavFile: string;
  OutFile: string;



begin

  try

    if ParamCount <> 2 then
    begin
      ShowUsage;
      Exit;
    end;


    WavFile :=
      ParamStr(1);

    OutFile :=
      ParamStr(2);



    DecodeSMC70(
      WavFile,
      OutFile
    );


  except

    on E: Exception do
    begin

      Writeln;
      Writeln(
        'ERROR: ',
        E.Message
      );

      ExitCode := 1;

    end;

  end;

end.
