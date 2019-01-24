{*******************************************************************************
  ����: dmzn@163.com 2019-01-22
  ����: ʵ�ֶ���־�Ļ���͹���
*******************************************************************************}
unit UMgrLog;

interface

uses
  System.Classes, System.SysUtils, UBaseObject, UThreadPool, UWaitItem,
  ULibFun;

type
  TLogType = (ltNull, ltInfo, ltWarn, ltError);
  //��־����:��,��Ϣ,����,����
  TLogTag = set of (ltWriteFile, ltWriteDB, ltWriteCMD);
  //��־���

  TLogWriter = record
    FOjbect  : TClass;             //�������
    FDesc    : string;             //������Ϣ
  end;

  PLogItem = ^TLogItem;
  TLogItem = record
    FWriter  : TLogWriter;         //��־����
    FLogTag  : TLogTag;            //��־���
    FType    : TLogType;           //��־����
    FTime    : TDateTime;          //��־ʱ��
    FEvent   : string;             //��־����
  end;

  //****************************************************************************
  TLogManager = class;
  TLogEvent = procedure (const nManager: TLogManager;
    const nLogItem: PLogItem) of object;
  TWriteLogProcedure = procedure (const nManager: TLogManager;
    const nLogItems: TList);
  TWriteLogEvent = procedure (const nManager: TLogManager;
    const nLogItems: TList) of object;
  //��־�¼�,�ص�����

  TLogManager = class(TManagerBase)
  public
    class var
      FFileExt: string;
      {*��־��չ��*}
      FLogField: string;
      {*��־�ָ���*}
  private
    FItemID: Cardinal;
    {*���ݱ�ʶ*}
    FBuffer: TList;
    FWriterBuffer: TList;
    {*������*}
    FWritePath: string;
    FWriteLock: TCrossProcWaitObject;
    FWriter: TThreadWorkerConfig;
    {*д��־�߳�*}
    FOnNewLog: TLogEvent;
    FEvent: TWriteLogEvent;
    FProcedure: TWriteLogProcedure;
    {*�¼�����*}
  protected
    procedure ClearList(const nList: TList; const nFree: Boolean = False);
    {*������Դ*}
    procedure DoThreadWrite(const nConfig: PThreadWorkerConfig;
      const nThread: TThread);
    procedure DoWriteFile(const nLogItems: TList);
    {*ִ��д��*}
    procedure WriteErrorLog(const nList: TList);
    {*д�����*}
  public
    constructor Create;
    destructor Destroy; override;
    {*�����ͷ�*}
    class procedure RegistMe(const nReg: Boolean); override;
    {*ע�����*}
    procedure RunAfterRegistAllManager; override;
    procedure RunBeforUnregistAllManager; override;
    {*�ӳ�ִ��*}
    function HasItem: Boolean;
    procedure InitItem(var nItem: TLogItem);
    {*��ʼ��*}
    procedure AddLog(const nItem: PLogItem); overload;
    procedure AddLog(const nEvent: string;
     const nType: TLogType = ltNull); overload;
    procedure AddLog(const nObj: TClass; const nDesc,nEvent: string;
     const nType: TLogType = ltNull); overload;
    {*����־*}
    procedure StartService(const nPath: string; const nSyncLock: string = '');
    procedure StopService();
    {*��ͣ����*}
    class function Type2Str(const nType: TLogType;
      const nLong: Boolean = True): string;
    class function Str2Type(const nStr: string;
      const nLong: Boolean = True): TLogType;
    {*��־����*}
    procedure GetStatus(const nList: TStrings;
      const nFriendly: Boolean = True); override;
    function GetHealth(const nList: TStrings = nil): TObjectHealth; override;
    {*��ȡ״̬*}
    property OnNewLog: TLogEvent read FOnNewLog write FOnNewLog;
    property WriteEvent: TWriteLogEvent read FEvent write FEvent;
    property WriteProcedure: TWriteLogProcedure read FProcedure write FProcedure;
    {*�����¼�*}
  end;

var
  gLogManager: TLogManager = nil;
  //ȫ��ʹ��

implementation

uses
  UManagerGroup;

constructor TLogManager.Create;
begin
  inherited;
  FWritePath := '';
  FWriteLock := nil;
end;

destructor TLogManager.Destroy;
begin
  FreeAndNil(FWriteLock);
  inherited;
end;

//Date: 2019-01-23
//Parm: �Ƿ�ע��
//Desc: ��ϵͳע�����������
class procedure TLogManager.RegistMe(const nReg: Boolean);
var nIdx: Integer;
begin
  nIdx := GetMe(TLogManager);
  if nReg then
  begin
    if not Assigned(gMG.FManagers[nIdx].FManager) then
      gMG.FManagers[nIdx].FManager := TLogManager.Create;
    gMG.FLogManager := gMG.FManagers[nIdx].FManager as TLogManager;
  end else
  begin
    gMG.FLogManager := nil;
    FreeAndNil(gMG.FManagers[nIdx].FManager);
  end;
end;

procedure TLogManager.RunAfterRegistAllManager;
begin
  gMG.CheckSupport('TLogManager', ['TThreadPoolManager', 'TMemDataManager']);
  //���֧��

  FBuffer := TList.Create;
  FWriterBuffer := TList.Create;
  //����������

  FItemID := gMG.FMemDataManager.NewType('TLogManager.LogItem', 'Data',
    function (): Pointer //Desc: �����ڴ�
    var nItem: PLogItem;
    begin
      New(nItem);
      Result := nItem;
    end,
    procedure (const nData: Pointer) //Desc: �ͷ��ڴ�
    begin
      Dispose(PLogItem(nData));
    end
  );

  gMG.FThreadPool.WorkerInit(FWriter);
  with FWriter do
  begin
    FWorkerName   := 'TLogManager.Writer';
    FParentObj    := Self;
    FParentDesc   := '��־������';
    FCallTimes    := 0; //��ͣ
    FCallInterval := 500;
    FProcEvent    := DoThreadWrite;
  end;

  gMG.FThreadPool.WorkerAdd(@FWriter);
  //�����߳���ҵ
end;

procedure TLogManager.RunBeforUnregistAllManager;
begin
  if Assigned(gMG.FThreadPool) then
    gMG.FThreadPool.WorkerDelete(Self);
  //ֹͣ�߳�

  SyncEnter;
  try
    ClearList(FBuffer, True);
    ClearList(FWriterBuffer, True); //�����б�
  finally
    SyncLeave;
  end;

  if Assigned(gMG.FMemDataManager) then
    gMG.FMemDataManager.DeleteType(FItemID);
  //�ͷ�
end;

procedure TLogManager.ClearList(const nList: TList; const nFree: Boolean);
var nIdx: Integer;
begin
  for nIdx := nList.Count-1 downto 0 do
    gMG.FMemDataManager.Release(nList[nIdx]);
  //xxxxx

  if nFree then
       nList.Free
  else nList.Clear;
end;

//Date: 2019-01-24
//Parm: ��־��
//Desc: ��ʼ��nItem
procedure TLogManager.InitItem(var nItem: TLogItem);
var nInit: TLogItem;
begin
  FillChar(nInit, SizeOf(TLogItem), #0);
  nItem := nInit;
  nItem.FLogTag := [];
  nItem.FTime := Now();
end;

//Desc: ������־��
procedure TLogManager.AddLog(const nItem: PLogItem);
var nP: PLogItem;
begin
  if Assigned(FOnNewLog) then
    FOnNewLog(Self, nItem);
  //��������,�����߳�д��

  if nItem.FLogTag = [] then Exit;
  //���账��

  SyncEnter;
  try
    nP := gMG.FMemDataManager.LockData(FItemID);
    FBuffer.Add(nP);
    nP^ := nItem^;
  finally
    SyncLeave;
  end;

  gMG.FThreadPool.WorkerWakeup(Self);
end;

//Desc: �ض�������־
procedure TLogManager.AddLog(const nObj: TClass; const nDesc, nEvent: string;
  const nType: TLogType);
var nItem: TLogItem;
begin
  with nItem do
  begin
    FWriter.FOjbect := nObj;
    FWriter.FDesc := nDesc;

    FType := nType;
    FLogTag := [ltWriteFile];
    nItem.FTime := Now();
    FEvent := nEvent;
  end;

  AddLog(@nItem);
  //put-in buffer
end;

//Desc: Ĭ����־
procedure TLogManager.AddLog(const nEvent: string; const nType: TLogType);
begin
  AddLog(TLogManager, 'Ĭ����־����', nEvent, nType);
end;

function TLogManager.HasItem: Boolean;
var nIdx,nCount: integer;
begin
  SyncEnter;
  try
    if FWriterBuffer.Count < 1 then
    begin
      nCount := FBuffer.Count - 1;
      for nIdx:=0 to nCount do
        FWriterBuffer.Add(FBuffer[nIdx]);
      FBuffer.Clear;
    end;

    Result := FWriterBuffer.Count > 0;
  finally
    SyncLeave;
  end;
end;

//Date: 2019-01-24
//Parm: ��־Ŀ¼;ͬ����ʶ
//Desc: ������־����,��nPath��д����־
procedure TLogManager.StartService(const nPath, nSyncLock: string);
begin
  StopService();
  //stop first

  if nPath = '' then
  begin
    FWritePath := '';
    gMG.FThreadPool.WorkerStart(Self);
    Exit;
  end;

  if not DirectoryExists(nPath) then
    ForceDirectories(nPath);
  FWritePath := nPath;

  if not Assigned(FWriteLock) then
    FWriteLock := TCrossProcWaitObject.Create(nSyncLock);
  //for thread or process sync
  gMG.FThreadPool.WorkerStart(Self);
end;

//Date: 2019-01-24
//Desc: ֹͣ����
procedure TLogManager.StopService;
begin
  gMG.FThreadPool.WorkerStop(Self);
  //stop thread

  SyncEnter;
  try
    ClearList(FBuffer);
    ClearList(FWriterBuffer);
  finally
    SyncLeave;
  end;
end;

procedure TLogManager.DoThreadWrite(const nConfig: PThreadWorkerConfig;
  const nThread: TThread);
begin
  if not HasItem then Exit;
  //try save all when thread terminated

  if nConfig.FDataInteger[0] > 1 then
  begin
    nConfig.FDataInteger[0] := 0;
    ClearList(FWriterBuffer);
  end;

  if FWriterBuffer.Count > 0 then
  try
    if FWritePath <> '' then
      DoWriteFile(FWriterBuffer);
    //write file

    if Assigned(FEvent) then
       FEvent(Self, FWriterBuffer);
    if Assigned(FProcedure) then
       FProcedure(Self, FWriterBuffer);
    //xxxxx

    nConfig.FDataInteger[0] := 0;
    ClearList(FWriterBuffer);
  except
    if nConfig.FDataInteger[0] = 0 then
      WriteErrorLog(FWriterBuffer);
    Inc(nConfig.FDataInteger[0]);
  end;
end;

//Date: 2019-01-24
//Parm: ��־�б�
//Desc: ��nLogItemsд���ļ�
procedure TLogManager.DoWriteFile(const nLogItems: TList);
var nStr: string;
    nFile: TextFile;
    nItem: PLogItem;
    i,nCount: integer;
begin
  FWriteLock.SyncLockEnter(True);
  try
    nStr := FWritePath + TDateTimeHelper.Date2Str(Now) + FFileExt;
    AssignFile(nFile, nStr);

    if FileExists(nStr) then
         Append(nFile)
    else Rewrite(nFile);

    nCount := nLogItems.Count - 1;
    for i:=0 to nCount do
    begin
      nItem := nLogItems[i];
      if not (ltWriteFile in nItem.FLogTag) then Continue;
      //��д�ļ�

      nStr := Copy(nItem.FWriter.FOjbect.ClassName, 1, 15);
      nStr := TDateTimeHelper.DateTime2Str(nItem.FTime) + ' ' +
              TLogManager.Type2Str(nItem.FType, False) + FLogField +
              nStr + FLogField;
      //ʱ��,����

      if nItem.FWriter.FDesc <> '' then
        nStr := nStr + nItem.FWriter.FDesc + FLogField;      //����
      nStr := nStr + nItem.FEvent;                           //�¼�
      WriteLn(nFile, nStr);
    end;
  finally
    CloseFile(nFile);
    FWriteLock.SyncLockLeave(True);
  end;
end;

procedure TLogManager.WriteErrorLog(const nList: TList);
var nItem: PLogItem;
begin
  nItem := gMG.FMemDataManager.LockData(FItemID);
  nList.Insert(0, nItem);

  nItem.FLogTag := [ltWriteFile];
  nItem.FType := ltError;
  nItem.FWriter.FOjbect := TLogManager;
  nItem.FWriter.FDesc := '��־�߳�';
  nItem.FEvent := Format('��%d����־д��ʧ��,�ٴγ���.', [nList.Count]);
end;

class function TLogManager.Str2Type(const nStr: string;
  const nLong: Boolean): TLogType;
var nU: string;
begin
  nU := UpperCase(Trim(nStr));
  //��ʽ��

  if nLong then
  begin
    if nU = 'INFO' then Result := ltInfo else
    if nU = 'WARN' then Result := ltWarn else
    if nU = 'ERROR' then Result := ltError else Result := ltNull;
  end else
  begin
    if nU = 'I' then Result := ltInfo else
    if nU = 'W' then Result := ltWarn else
    if nU = 'E' then Result := ltError else Result := ltNull;
  end;
end;

//Date: 2019-01-23
//Parm: ����;������
//Desc: ����ת����
class function TLogManager.Type2Str(const nType: TLogType;
  const nLong: Boolean): string;
begin
  if nLong then
  begin
    case nType of
     ltInfo: Result := 'INFO';
     ltWarn: Result := 'WARN';
     ltError: Result := 'ERROR' else Result := '';
    end;
  end else
  begin
    case nType of
     ltInfo: Result := 'I';
     ltWarn: Result := 'W';
     ltError: Result := 'E' else Result := '';
    end;
  end;
end;

function TLogManager.GetHealth(const nList: TStrings): TObjectHealth;
begin
  SyncEnter;
  try
    Result := hlNormal;
  finally
    SyncLeave;
  end;
end;

procedure TLogManager.GetStatus(const nList: TStrings;
  const nFriendly: Boolean);
begin
  with TObjectStatusHelper do
  try
    SyncEnter;
    inherited GetStatus(nList, nFriendly);

    if not nFriendly then
    begin
      //nList.Add('NumWorkerMax' + FNumWorkerMax.ToString);

      Exit;
    end;

    //nList.Add(FixData('NumWorkerMax:', FStatus.FNumWorkerMax));
  finally
    SyncLeave;
  end;
end;

initialization
  with TLogManager do
  begin
    FFileExt := '.log';
    FLogField := #9;
  end;
finalization
  //nothing
end.