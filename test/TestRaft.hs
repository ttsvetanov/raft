{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}

module TestRaft where

import Protolude
import qualified Data.Sequence as Seq
import Data.Sequence (Seq(..), (|>))
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Serialize as S
import Numeric.Natural
import Control.Monad.Conc.Class (throw)

import qualified Test.Tasty.HUnit as HUnit

import TestUtils

import Raft hiding (sendClient)
import Raft.Logging (logMsgToText, logMsgData, logMsgNodeId, LogMsg)
import Raft.Action
import Raft.Handle
import Raft.Log
import Raft.Monad
import Raft.NodeState
import Raft.Types
import Raft.RPC

------------------------------
-- State Machine & Commands --
------------------------------

type Var = ByteString

data StoreCmd
  = Set Var Natural
  | Incr Var
  deriving (Show, Generic)

instance S.Serialize StoreCmd

type Store = Map Var Natural

instance RSMP Store StoreCmd where
  data RSMPError Store StoreCmd = StoreError Text deriving (Show)
  type RSMPCtx Store StoreCmd = ()
  applyCmdRSMP _ store cmd =
    Right $ case cmd of
      Set x n -> Map.insert x n store
      Incr x -> Map.adjust succ x store

testVar :: Var
testVar = "test"

testInitVal :: Natural
testInitVal = 1

testSetCmd :: StoreCmd
testSetCmd = Set testVar testInitVal

testIncrCmd :: StoreCmd
testIncrCmd = Incr testVar

--------------------
-- Scenario v Monad --
--------------------

type ClientResps = Map ClientId (Seq (ClientResponse Store))

data TestState v = TestState
  { testNodeIds :: NodeIds
  , testNodeLogs :: Map NodeId (Entries StoreCmd)
  , testNodeSMs :: Map NodeId Store
  , testNodeRaftStates :: Map NodeId (RaftNodeState v)
  , testNodePersistentStates :: Map NodeId PersistentState
  , testNodeConfigs :: Map NodeId NodeConfig
  , testClientResps :: ClientResps
  } deriving (Show)

type Scenario v a = StateT (TestState v) IO a

-- | Run scenario monad with initial state
runScenario :: Scenario v () -> IO ()
runScenario scenario = do
  let initPersistentState = PersistentState term0 Nothing
  let initTestState = TestState
                    { testNodeIds = nodeIds
                    , testNodeLogs = Map.fromList $ (, mempty) <$> Set.toList nodeIds
                    , testNodeSMs = Map.fromList $ (, mempty) <$> Set.toList nodeIds
                    , testNodeRaftStates = Map.fromList $ (, initRaftNodeState) <$> Set.toList nodeIds
                    , testNodePersistentStates = Map.fromList $ (, initPersistentState) <$> Set.toList nodeIds
                    , testNodeConfigs = Map.fromList $ zip (Set.toList nodeIds) testConfigs
                    , testClientResps = Map.fromList [(client0, mempty)]
                    }

  evalStateT scenario initTestState

updateStateMachine :: NodeId -> Store -> Scenario v ()
updateStateMachine nodeId sm
  = modify $ \testState@TestState{..}
      -> testState
          { testNodeSMs = Map.insert nodeId sm testNodeSMs
          }

updatePersistentState :: NodeId -> PersistentState -> Scenario v ()
updatePersistentState nodeId persistentState
  = modify $ \testState@TestState{..}
      -> testState
          { testNodePersistentStates = Map.insert nodeId persistentState testNodePersistentStates
          }

updateRaftNodeState :: NodeId -> RaftNodeState v -> Scenario v ()
updateRaftNodeState nodeId raftState
  = modify $ \testState@TestState{..}
      -> testState
          { testNodeRaftStates = Map.insert nodeId raftState testNodeRaftStates
          }

getNodeInfo :: NodeId -> Scenario v (NodeConfig, Store, RaftNodeState v, PersistentState)
getNodeInfo nId = do
  nodeConfigs <- gets testNodeConfigs
  nodeSMs <- gets testNodeSMs
  nodeRaftStates <- gets testNodeRaftStates
  nodePersistentStates <- gets testNodePersistentStates
  let Just nodeInfo = Map.lookup nId nodeConfigs >>= \config ->
                  Map.lookup nId nodeSMs >>= \store ->
                  Map.lookup nId nodeRaftStates >>= \raftState ->
                  Map.lookup nId nodePersistentStates >>= \persistentState ->
                  pure (config, store, raftState, persistentState)
  pure nodeInfo


lookupClientResps :: ClientId -> ClientResps -> Seq (ClientResponse Store)
lookupClientResps clientId cResps =
  case Map.lookup clientId cResps of
    Nothing -> panic "Client id not found"
    Just resps -> resps

lookupLastClientResp :: ClientId -> ClientResps -> ClientResponse Store
lookupLastClientResp clientId cResps = r
  where
    (_ :|> r) = lookupClientResps clientId cResps

sendClient :: ClientId -> ClientResponse Store -> Scenario v ()
sendClient clientId resp = do
  cResps <- gets testClientResps
  let resps = lookupClientResps clientId cResps
  modify (\st -> st { testClientResps = Map.insert clientId (resps |> resp) (testClientResps st) })

-------------------
-- Log instances --
-------------------

newtype NodeEnvError = NodeEnvError Text
  deriving (Show)

instance Exception NodeEnvError

type RTLog v = ReaderT NodeId (StateT (TestState v) IO)

instance RaftWriteLog (RTLog v) StoreCmd where
  type RaftWriteLogError (RTLog v) = NodeEnvError
  writeLogEntries newEntries = do
    nid <- ask
    Just log <- Map.lookup nid <$> gets testNodeLogs
    fmap Right $ modify $ \testState@TestState{..} ->
      testState { testNodeLogs = Map.insert nid (log Seq.>< newEntries) testNodeLogs }

instance RaftReadLog (RTLog v) StoreCmd where
  type RaftReadLogError (RTLog v) = NodeEnvError
  readLogEntry (Index idx) = do
    nid <- ask
    Just log <- Map.lookup nid <$> gets testNodeLogs
    case log Seq.!? fromIntegral (if idx == 0 then 0 else idx - 1) of
      Nothing -> pure (Right Nothing)
      Just e -> pure (Right (Just e))
  readLastLogEntry = do
    nid <- ask
    Just log <- Map.lookup nid <$> gets testNodeLogs
    case log of
      Seq.Empty -> pure (Right Nothing)
      (_ Seq.:|> e) -> pure (Right (Just e))

instance RaftDeleteLog (RTLog v) StoreCmd where
  type RaftDeleteLogError (RTLog v) = NodeEnvError
  deleteLogEntriesFrom idx = do
    nid <- ask
    Just log <- Map.lookup nid <$> gets testNodeLogs
    fmap (const (Right DeleteSuccess)) $ modify $ \testState@TestState{..} ->
      testState { testNodeLogs = Map.insert nid (Seq.dropWhileR ((>= idx) . entryIndex) log) testNodeLogs }

-------------------------------
-- Handle actions and events --
-------------------------------

testHandleLogs :: Maybe [NodeId] -> (Text -> IO ()) -> [LogMsg] -> Scenario v ()
testHandleLogs nIdsM f logs = liftIO $
  case nIdsM of
    Nothing -> mapM_ (f . logMsgToText) logs
    Just nIds ->
      mapM_ (f . logMsgToText) $ flip filter logs $ \log ->
        logMsgNodeId (logMsgData log) `elem` nIds

testHandleActions :: NodeId -> [Action Store StoreCmd] -> Scenario StoreCmd ()
testHandleActions sender =
  mapM_ (testHandleAction sender)

testHandleAction :: NodeId -> Action Store StoreCmd -> Scenario StoreCmd ()
testHandleAction sender action = do
  case action of
    SendRPC nId rpcAction -> do
      msg <- mkRPCfromSendRPCAction sender rpcAction
      testHandleEvent nId (MessageEvent (RPCMessageEvent msg))
    SendRPCs msgs ->
      mapM_ (\(nId, rpcAction) -> do
          msg <- mkRPCfromSendRPCAction sender rpcAction
          testHandleEvent nId (MessageEvent (RPCMessageEvent msg))
        ) (Map.toList msgs)
    BroadcastRPC nIds rpcAction -> mapM_ (\nId -> do
      msg <- mkRPCfromSendRPCAction sender rpcAction
      testHandleEvent nId (MessageEvent (RPCMessageEvent msg))) nIds
    RespondToClient clientId resp -> sendClient clientId resp
    ResetTimeoutTimer _ -> noop
    AppendLogEntries entries -> do
      runReaderT (updateLog entries) sender
      modify $ \testState@TestState{..}
        -> case Map.lookup sender testNodeRaftStates of
            Nothing -> panic "No NodeState"
            Just (RaftNodeState ns) -> testState
              { testNodeRaftStates = Map.insert sender (RaftNodeState (setLastLogEntry ns entries)) testNodeRaftStates
              }
    where
      noop = pure ()

      mkRPCfromSendRPCAction
        :: NodeId -> SendRPCAction StoreCmd -> Scenario v (RPCMessage StoreCmd)
      mkRPCfromSendRPCAction nId sendRPCAction = do
        sc <- get
        (nodeConfig, _, raftState@(RaftNodeState ns), _) <- getNodeInfo nId
        RPCMessage (configNodeId nodeConfig) <$>
          case sendRPCAction of
            SendAppendEntriesRPC aeData -> do
              (entries, prevLogIndex, prevLogTerm, aeReadReq) <-
                case aedEntriesSpec aeData of
                  FromIndex idx -> do
                    eLogEntries <- runReaderT (readLogEntriesFrom (decrIndexWithDefault0 idx)) nId
                    case eLogEntries of
                      Left err -> throw err
                      Right log ->
                        case log of
                          pe :<| entries@(e :<| _)
                            | idx == 1 -> pure (log, index0, term0, Nothing)
                            | otherwise -> pure (entries, entryIndex pe, entryTerm pe, Nothing)
                          _ -> pure (log, index0, term0, Nothing)
                  FromClientWriteReq e -> prevEntryData nId e
                  FromNewLeader e -> prevEntryData nId e
                  NoEntries spec -> do
                    let readReq' =
                          case spec of
                            FromClientReadReq n -> Just n
                            _ -> Nothing
                        (lastLogIndex, lastLogTerm) = lastLogEntryIndexAndTerm (getLastLogEntry ns)
                    pure (Empty, lastLogIndex, lastLogTerm, readReq')
              let leaderId = LeaderId (configNodeId nodeConfig)
              pure . toRPC $
                AppendEntries
                  { aeTerm = aedTerm aeData
                  , aeLeaderId = leaderId
                  , aePrevLogIndex = prevLogIndex
                  , aePrevLogTerm = prevLogTerm
                  , aeEntries = entries
                  , aeLeaderCommit = aedLeaderCommit aeData
                  , aeReadRequest = aeReadReq
                  }
            SendAppendEntriesResponseRPC aer -> do
              pure (toRPC aer)
            SendRequestVoteRPC rv -> pure (toRPC rv)
            SendRequestVoteResponseRPC rvr -> pure (toRPC rvr)

      prevEntryData nId e = do
        (x,y,z) <- prevEntryData' nId e
        pure (x,y,z,Nothing)

      prevEntryData' nId e
        | entryIndex e == Index 1 = pure (Seq.singleton e, index0, term0)
        | otherwise = do
            eLogEntry <- runReaderT (readLogEntry (decrIndexWithDefault0 (entryIndex e))) nId
            case eLogEntry of
              Left err -> throw err
              Right Nothing -> pure (Seq.singleton e, index0, term0)
              Right (Just (prevEntry :: Entry StoreCmd)) ->
                pure (Seq.singleton e, entryIndex prevEntry, entryTerm prevEntry)

testHandleEvent :: NodeId -> Event StoreCmd -> Scenario StoreCmd ()
testHandleEvent nodeId event = do
  (nodeConfig, sm, raftState', persistentState) <- getNodeInfo nodeId
  raftState <- loadLogEntryTermAtAePrevLogIndex raftState'
  let transitionEnv = TransitionEnv nodeConfig sm raftState
  let (newRaftState, newPersistentState, actions, logMsgs) = handleEvent raftState transitionEnv persistentState event
  updatePersistentState nodeId newPersistentState
  updateRaftNodeState nodeId newRaftState
  testHandleActions nodeId actions
  testHandleLogs Nothing (const $ pure ()) logMsgs
  applyLogEntries nodeId sm
  where
    applyLogEntries
      :: NodeId
      -> Store
      -> Scenario v ()
    applyLogEntries nId stateMachine  = do
        (_, _, raftNodeState@(RaftNodeState nodeState), _) <- getNodeInfo nId
        let lastAppliedIndex = lastApplied nodeState
        when (commitIndex nodeState > lastAppliedIndex) $ do
          let resNodeState = incrLastApplied nodeState
          modify $ \testState@TestState{..} -> testState {
              testNodeRaftStates = Map.insert nId (RaftNodeState resNodeState) testNodeRaftStates }
          let newLastAppliedIndex = lastApplied resNodeState
          eLogEntry <- runReaderT (readLogEntry newLastAppliedIndex) nId
          case eLogEntry of
            Left err -> throw err
            Right Nothing -> panic "No log entry at 'newLastAppliedIndex'"
            Right (Just logEntry) -> do
              case entryValue logEntry of
                NoValue -> applyLogEntries nId stateMachine
                EntryValue v -> do
                  let Right newStateMachine = applyCmdRSMP () stateMachine v
                  updateStateMachine nId newStateMachine
                  applyLogEntries nId newStateMachine

      where
        incrLastApplied :: NodeState ns v -> NodeState ns v
        incrLastApplied nodeState =
          case nodeState of
            NodeFollowerState fs ->
              let lastApplied' = incrIndex (fsLastApplied fs)
               in NodeFollowerState $ fs { fsLastApplied = lastApplied' }
            NodeCandidateState cs ->
              let lastApplied' = incrIndex (csLastApplied cs)
               in  NodeCandidateState $ cs { csLastApplied = lastApplied' }
            NodeLeaderState ls ->
              let lastApplied' = incrIndex (lsLastApplied ls)
               in NodeLeaderState $ ls { lsLastApplied = lastApplied' }

        lastApplied :: NodeState ns v -> Index
        lastApplied = fst . getLastAppliedAndCommitIndex

        commitIndex :: NodeState ns v -> Index
        commitIndex = snd . getLastAppliedAndCommitIndex

    -- In the case that a node is a follower receiving an AppendEntriesRPC
    -- Event, read the log at the aePrevLogIndex
    loadLogEntryTermAtAePrevLogIndex :: RaftNodeState v -> Scenario v (RaftNodeState v)
    loadLogEntryTermAtAePrevLogIndex (RaftNodeState rns) =
      case event of
        MessageEvent (RPCMessageEvent (RPCMessage _ (AppendEntriesRPC ae))) -> do
          case rns of
            NodeFollowerState fs -> do
              eEntry <- runReaderT (readLogEntry (aePrevLogIndex ae)) nodeId
              case eEntry of
                Left err -> throw err
                Right (mEntry :: Maybe (Entry StoreCmd)) ->
                  pure $ RaftNodeState $ NodeFollowerState fs
                    { fsTermAtAEPrevIndex = entryTerm <$> mEntry }
            _ -> pure (RaftNodeState rns)
        _ -> pure (RaftNodeState rns)

testHeartbeat :: NodeId -> Scenario StoreCmd ()
testHeartbeat sender = do
  nodeRaftStates <- gets testNodeRaftStates
  nodePersistentStates <- gets testNodePersistentStates
  nIds <- gets testNodeIds
  let Just raftState = Map.lookup sender nodeRaftStates
      Just persistentState = Map.lookup sender nodePersistentStates
  unless (isRaftLeader raftState) $ panic $ toS (show sender ++ " must a be a leader to heartbeat")
  let LeaderState{..} = getInnerLeaderState raftState
  let aeData = AppendEntriesData
                        { aedTerm = currentTerm persistentState
                        , aedEntriesSpec = NoEntries FromHeartbeat
                        , aedLeaderCommit = lsCommitIndex
                        }

  -- Broadcast AppendEntriesRPC
  testHandleAction sender
    (BroadcastRPC (Set.filter (sender /=) nIds) (SendAppendEntriesRPC aeData))
  where
    getInnerLeaderState :: RaftNodeState StoreCmd -> LeaderState StoreCmd
    getInnerLeaderState nodeState = case nodeState of
      (RaftNodeState (NodeLeaderState leaderState)) -> leaderState
      _ -> panic "Node must be a leader to access its leader state"


----------------------
-- Test raft events --
----------------------

testInitLeader :: NodeId -> Scenario StoreCmd ()
testInitLeader nId =
  testHandleEvent nId (TimeoutEvent ElectionTimeout)

testClientReadRequest :: NodeId -> Scenario StoreCmd ()
testClientReadRequest nId =
  testHandleEvent nId (MessageEvent
        (ClientRequestEvent
          (ClientRequest client0 ClientReadReq)))

testClientWriteRequest :: StoreCmd -> NodeId -> Scenario StoreCmd ()
testClientWriteRequest cmd nId =
  testHandleEvent nId (MessageEvent
        (ClientRequestEvent
          (ClientRequest client0 (ClientWriteReq cmd))))

----------------
-- Unit tests --
----------------

-- When the protocol starts, every node is a follower
unit_init_protocol :: IO ()
unit_init_protocol = runScenario $ do
  -- Node 0 becomes the leader
  testInitLeader node0

  raftStates <- gets testNodeRaftStates

  -- Node0 has become leader and other nodes are followers
  liftIO $ assertLeader raftStates [(node0, NoLeader), (node1, CurrentLeader (LeaderId node0)), (node2, CurrentLeader (LeaderId node0))]
  liftIO $ assertNodeState raftStates [(node0, isRaftLeader), (node1, isRaftFollower), (node2, isRaftFollower)]

unit_append_entries_client_request :: IO ()
unit_append_entries_client_request = runScenario $ do

  testInitLeader node0

  raftStates0 <- gets testNodeRaftStates
  sms0 <- gets testNodeSMs
  logs0 <- gets testNodeLogs

  liftIO $ assertPersistedLogs logs0 [(node0, 1), (node1, 1), (node2, 1)]
  liftIO $ assertCommittedLogIndex raftStates0 [(node0, Index 1), (node1, Index 0), (node2, Index 0)]
  liftIO $ assertAppliedLogIndex raftStates0 [(node0, Index 1), (node1, Index 0), (node2, Index 0)]
  liftIO $ assertSMs sms0 [(node0, mempty), (node1, mempty), (node2, mempty)]

  testClientWriteRequest testSetCmd node0

  raftStates1 <- gets testNodeRaftStates
  sms1 <- gets testNodeSMs
  logs1 <- gets testNodeLogs

  liftIO $ assertPersistedLogs logs1 [(node0, 2), (node1, 2), (node2, 2)]
  liftIO $ assertCommittedLogIndex raftStates1 [(node0, Index 2), (node1, Index 1), (node2, Index 1)]
  liftIO $ assertAppliedLogIndex raftStates1 [(node0, Index 2), (node1, Index 1), (node2, Index 1)]
  liftIO $ assertSMs sms1 [(node0, Map.fromList [(testVar, testInitVal)]), (node1, mempty), (node2, mempty)]

  ---------------------------- HEARTBEAT 1 ------------------------------
  -- After leader heartbeats, followers commit and apply leader's entries
  testHeartbeat node0

  raftStates2 <- gets testNodeRaftStates
  sms2 <- gets testNodeSMs
  logs2 <- gets testNodeLogs

  liftIO $ assertPersistedLogs logs2 [(node0, 2), (node1, 2), (node2, 2)]
  liftIO $ assertCommittedLogIndex raftStates2 [(node0, Index 2), (node1, Index 2), (node2, Index 2)]
  liftIO $ assertAppliedLogIndex raftStates2 [(node0, Index 2), (node1, Index 2), (node2, Index 2)]
  liftIO $ assertSMs sms2 [(node0, Map.fromList [(testVar, testInitVal)]), (node1, Map.fromList [(testVar, testInitVal)]), (node2, Map.fromList [(testVar, testInitVal)])]



unit_incr_value :: IO ()
unit_incr_value = runScenario $ do
  testInitLeader node0
  testClientWriteRequest testSetCmd node0
  testClientWriteRequest testIncrCmd node0

  testHeartbeat node0

  sms <- gets testNodeSMs
  liftIO $ assertSMs sms [(node0, Map.fromList [(testVar, succ testInitVal)]), (node1, Map.fromList [(testVar, succ testInitVal)]), (node2, Map.fromList [(testVar, succ testInitVal)])]


unit_mult_incr_value :: IO ()
unit_mult_incr_value = runScenario $ do
  testInitLeader node0
  testClientWriteRequest testSetCmd node0
  let reps = 10
  replicateM_ (fromIntegral 10) (testClientWriteRequest testIncrCmd node0)
  testHeartbeat node0

  sms <- gets testNodeSMs
  liftIO $ assertSMs sms [(node0, Map.fromList [(testVar, testInitVal + reps)]), (node1, Map.fromList [(testVar, testInitVal + reps)]), (node2, Map.fromList [(testVar, testInitVal + reps)])]

unit_client_req_no_leader :: IO ()
unit_client_req_no_leader = runScenario $ do
  testClientWriteRequest testSetCmd node1
  cResps <- gets testClientResps
  let ClientRedirectResponse (ClientRedirResp lResp) = lookupLastClientResp client0 cResps
  liftIO $ HUnit.assertBool "A follower should return a NoLeader response" (lResp == NoLeader)

unit_redirect_leader :: IO ()
unit_redirect_leader = runScenario $ do
  testInitLeader node0
  testClientWriteRequest testSetCmd node1
  cResps <- gets testClientResps
  let ClientRedirectResponse (ClientRedirResp (CurrentLeader (LeaderId lResp))) = lookupLastClientResp client0 cResps
  liftIO $ HUnit.assertBool "A follower should point to the current leader" (lResp == node0)

unit_client_read_response :: IO ()
unit_client_read_response = runScenario $ do
  testInitLeader node0
  testClientWriteRequest testSetCmd node0
  testClientReadRequest node0
  cResps <- gets testClientResps
  let ClientReadResponse (ClientReadResp store) = lookupLastClientResp client0 cResps
  liftIO $ HUnit.assertBool "A client should receive the current state of the store"
    (store == Map.fromList [(testVar, testInitVal)])

unit_client_write_response :: IO ()
unit_client_write_response = runScenario $ do
  testInitLeader node0
  testClientReadRequest node0
  testClientWriteRequest testSetCmd node0
  cResps <- gets testClientResps
  let ClientWriteResponse (ClientWriteResp idx) = lookupLastClientResp client0 cResps
  liftIO $ HUnit.assertBool "A client should receive an aknowledgement of a writing request"
    (idx == Index 2)

unit_new_leader :: IO ()
unit_new_leader = runScenario $ do
  testInitLeader node0
  testHandleEvent node1 (TimeoutEvent ElectionTimeout)
  raftStates <- gets testNodeRaftStates

  liftIO $ assertNodeState raftStates [(node0, isRaftFollower), (node1, isRaftLeader), (node2, isRaftFollower)]
  liftIO $ assertLeader raftStates [(node0, CurrentLeader (LeaderId node1)), (node1, NoLeader), (node2, CurrentLeader (LeaderId node1))]

------------------
-- Assert utils --
------------------

assertNodeState :: Map NodeId (RaftNodeState v) -> [(NodeId, RaftNodeState v -> Bool)] -> IO ()
assertNodeState raftNodeStates =
  mapM_ (\(nId, isNodeState) -> HUnit.assertBool (show nId ++ " should be in a different state")
    (maybe False isNodeState (Map.lookup nId raftNodeStates)))

assertLeader :: Map NodeId (RaftNodeState v) -> [(NodeId, CurrentLeader)] -> IO ()
assertLeader raftNodeStates =
  mapM_ (\(nId, leader) -> HUnit.assertBool (show nId ++ " should recognize " ++ show leader ++ " as its leader")
    (maybe False ((== leader) . checkCurrentLeader) (Map.lookup nId raftNodeStates)))

assertCommittedLogIndex :: Map NodeId (RaftNodeState v) -> [(NodeId, Index)] -> IO ()
assertCommittedLogIndex raftNodeStates =
  mapM_ (\(nId, idx) -> HUnit.assertBool (show nId ++ " should have " ++ show idx ++ " as its last committed index")
    (maybe False ((== idx) . getCommittedLogIndex) (Map.lookup nId raftNodeStates)))

assertAppliedLogIndex :: Map NodeId (RaftNodeState v) -> [(NodeId, Index)] -> IO ()
assertAppliedLogIndex raftNodeStates =
  mapM_ (\(nId, idx) -> HUnit.assertBool (show nId ++ " should have " ++ show idx ++ " as its last applied index")
    (maybe False ((== idx) . getLastAppliedLog) (Map.lookup nId raftNodeStates)))

assertPersistedLogs :: Map NodeId (Entries v) -> [(NodeId, Int)] -> IO ()
assertPersistedLogs persistedLogs =
  mapM_ (\(nId, len) -> HUnit.assertBool (show nId ++ " should have appended " ++ show len ++ " logs")
    (maybe False ((== len) . Seq.length) (Map.lookup nId persistedLogs)))

assertSMs :: Map NodeId Store -> [(NodeId, Store)] -> IO ()
assertSMs sms =
  mapM_ (\(nId, sm) -> HUnit.assertBool (show nId ++ " state machine " ++ show sm ++ " is not valid")
    (maybe False (== sm) (Map.lookup nId sms)))
