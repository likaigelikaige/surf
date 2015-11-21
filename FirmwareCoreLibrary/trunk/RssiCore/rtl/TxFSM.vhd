-------------------------------------------------------------------------------
-- Title      : 
-------------------------------------------------------------------------------
-- File       : TxFSM.vhd
-- Author     : Uros Legat  <ulegat@slac.stanford.edu>
-- Company    : SLAC National Accelerator Laboratory (Cosylab)
-- Created    : 2015-08-09
-- Last update: 2015-08-09
-- Platform   : 
-- Standard   : VHDL'93/02
-------------------------------------------------------------------------------
-- Description:
--             
-------------------------------------------------------------------------------
-- Copyright (c) 2015 SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;
use ieee.std_logic_arith.all;

use work.StdRtlPkg.all;
use work.RssiPkg.all;
use work.SsiPkg.all;
use work.AxiStreamPkg.all;

entity TxFSM is
   generic (
      TPD_G              : time     := 1 ns;
      
      WINDOW_ADDR_SIZE_G  : positive := 7;      -- 2^WINDOW_ADDR_SIZE_G  = Number of segments
 
      SYN_HEADER_SIZE_G  : natural := 24;
      ACK_HEADER_SIZE_G  : natural := 8;
      EACK_HEADER_SIZE_G : natural := 8;
      RST_HEADER_SIZE_G  : natural := 8;
      NULL_HEADER_SIZE_G : natural := 8;
      DATA_HEADER_SIZE_G : natural := 8
   );
   port (
      clk_i      : in  sl;
      rst_i      : in  sl;
      
      -- Connection FSM indicating active connection
      connActive_i   : in  sl;
      
      -- Various segment requests
      sndSyn_i        : in  sl;
      sndAck_i        : in  sl;
      sndRst_i        : in  sl;
      sndResend_i     : in  sl;
      sndNull_i       : in  sl;   
      
      -- Window buff size (Depends on the number of outstanding segments)
      windowSize_i  : in integer range 0 to 2 ** (WINDOW_ADDR_SIZE_G-1);
  
      -- Buffer write
      wrBuffWe_o     : out  sl;      
      wrBuffAddr_o   : out  slv( (SEGMENT_ADDR_SIZE_C+WINDOW_ADDR_SIZE_G)-1 downto 0);
      wrBuffData_o   : out  slv(RSSI_WORD_WIDTH_C*8-1 downto 0);      
      
      -- Buffer read
      rdBuffAddr_o   : out  slv( (SEGMENT_ADDR_SIZE_C+WINDOW_ADDR_SIZE_G)-1 downto 0);
      rdBuffData_i   : in   slv(RSSI_WORD_WIDTH_C*8-1 downto 0);
    
      -- Header read
      rdHeaderAddr_o  : out  slv(7 downto 0);
      rdHeaderData_i  : in slv(RSSI_WORD_WIDTH_C*8-1 downto 0);
      --
      headerRdy_i     : in sl;
      headerLength_i  : in positive;  -- Unconnected for now will be used when EACK    
      
      -- Checksum control
      chksumValid_i : in   sl;
      chksumEnable_o: out  sl;
      chksumStrobe_o: out  sl; 
      --      
      chksum_i : in slv(15 downto 0);      
      
      -- Initial sequence number
      initSeqN_i   : in slv(7 downto 0);
    
      -- Tx data (input to header decoder module)
      txSeqN_o     : out slv(7 downto 0);
      
      -- FSM outs for header and data flow control
      synHeadSt_o  : out  sl;
      ackHeadSt_o  : out  sl;
      dataHeadSt_o : out  sl;
      dataSt_o     : out  sl;
      rstHeadSt_o  : out  sl;
      nullHeadSt_o : out  sl;
      
      -- Last acked number (Used in Rx FSM to determine if AcnN is valid)
      lastAckN_o    : out slv(7 downto 0);
      
      -- Acknowledge mechanism
      ack_i         : in sl;                   -- From receiver module when a segment with valid ACK is received
      ackN_i        : in slv(7 downto 0);      -- Number being ACKed
      --eack_i        : in sl;                 -- From receiver module when a segment with valid EACK is received
      --eackSeqnArr_i : in Slv8Array(0 to MAX_RX_NUM_OUTS_SEG_G-1); -- Array of sequence numbers received out of order

      -- SSI Application side interface IN
      appSsiMaster_i : in  SsiMasterType;
      appSsiSlave_o  : out SsiSlaveType;
      
      -- SSI Transport side interface OUT
      tspSsiSlave_i  : in   SsiSlaveType;
      tspSsiMaster_o : out  SsiMasterType;
      
      -- Errors (1 cc pulse)
      lenErr_o         : out sl;
      ackErr_o         : out sl
      
   );
end entity TxFSM;

architecture rtl of TxFSM is

   -- Init SSI bus
   constant SSI_MASTER_INIT_C   : SsiMasterType := axis2SsiMaster(RSSI_AXI_CONFIG_C, AXI_STREAM_MASTER_INIT_C);
   constant SSI_SLAVE_NOTRDY_C  : SsiSlaveType  := axis2SsiSlave(RSSI_AXI_CONFIG_C, AXI_STREAM_SLAVE_INIT_C, AXI_STREAM_CTRL_INIT_C);
   constant SSI_SLAVE_RDY_C     : SsiSlaveType  := axis2SsiSlave(RSSI_AXI_CONFIG_C, AXI_STREAM_SLAVE_FORCE_C, AXI_STREAM_CTRL_UNUSED_C);
   
   type TspStateType is (
      --
      INIT_S,
      CONN_S,
      --
      SYN_H_S,
      ACK_H_S,
      RST_H_S,
      NULL_H_S,
      DATA_H_S,
      DATA_S,
      DATA_SENT_S,
      --
      RST_WE_S,
      DATA_WE_S,
      NULL_WE_S,
      --
      RESEND_INIT_S,
      RESEND_S,
      RESEND_H_S,
      RESEND_DATA_S,
      RESEND_PP_S
   );
   
   type AppStateType is (
      IDLE_S,
      WAIT_SOF_S,
      SEG_RCV_S,
      SEG_RDY_S,
      SEG_LEN_ERR,
      WAIT_TX_S
   );
   
   type AckStateType is (
      IDLE_S,
      ERR_S,
      ACK_S
      --EACK_S,
   );

   type RegType is record
   
      -- Buffer window handling and acknowledgment control
      -----------------------------------------
      windowArray    : WindowTypeArray(0 to 2 ** WINDOW_ADDR_SIZE_G-1);      
      firstUnackAddr : slv(WINDOW_ADDR_SIZE_G-1 downto 0);
      nextSentAddr   : slv(WINDOW_ADDR_SIZE_G-1 downto 0);
      lastSentAddr   : slv(WINDOW_ADDR_SIZE_G-1 downto 0);
      
      lastAckSeqN    : slv(7 downto 0);
      --eackAddr       : slv(WINDOW_ADDR_SIZE_G-1 downto 0);
      --eackIndex      : integer;      
      bufferFull     : sl;
      bufferEmpty    : sl;
      ackErr         : sl;     
      
      -- State Machine
      ackState       : AckStateType;
      
      -- Application side FSM
      -----------------------------------------     
      rxSegmentAddr  : slv(SEGMENT_ADDR_SIZE_C downto 0); -- One address bit more to check the overflow
      rxSegmentWe    : sl;
      sndData        : sl;
      lenErr         : sl;
      appBusy        : sl;
      
      appSsiMaster      : SsiMasterType;
      appSsiSlave       : SsiSlaveType;
      
      appState       : AppStateType;
   
      -- Transport side FSM
      -----------------------------------------
      
      -- Counters
      nextSeqN       : slv(7 downto 0);
      seqN           : slv(7 downto 0);
      txHeaderAddr   : slv(7 downto 0);
      txSegmentAddr  : slv(SEGMENT_ADDR_SIZE_C downto 0);
      txBufferAddr   : slv(WINDOW_ADDR_SIZE_G-1  downto 0);
      
      -- Data mux flags
      synH  : sl;
      ackH  : sl;      
      rstH  : sl;
      nullH : sl;
      dataH : sl;
      dataD : sl;
      resend: sl;

      -- Varionus controls
      txRdy    : sl;
      buffWe   : sl;
      buffSent : sl;
      chkEn    : sl;
      chkStb    : sl;
      
      -- SSI master
      tspSsiMaster      : SsiMasterType;
      tspSsiSlave       : SsiSlaveType;
      
      -- State Machine
      tspState       : tspStateType;    
   end record RegType;

   constant REG_INIT_C : RegType := (
   
      -- Buffer window handling and acknowledgment control
      -----------------------------------------
      -- Window control   
      firstUnackAddr => (others => '0'),
      lastSentAddr   => (others => '0'),
      nextSentAddr   => (others => '0'),
      
      lastAckSeqN    => (others => '0'),
      --eackAddr       => (others => '0'),
      --eackIndex      => 0,
      bufferFull     => '0',
      bufferEmpty    => '1',
      windowArray    => (0 to 2 ** WINDOW_ADDR_SIZE_G-1 => WINDOW_INIT_C),
      ackErr         => '0',
      
      ackState        => IDLE_S,
      
      -- Application side FSM
      -----------------------------------------     
      rxSegmentAddr   => (others => '0'),
      rxSegmentWe     => '0',
      sndData         => '0',
      lenErr          => '0',
      appBusy         => '0',
      
      appSsiMaster    => SSI_MASTER_INIT_C,     
      appSsiSlave     => SSI_SLAVE_NOTRDY_C,
      
      appState        => IDLE_S,
      
      -- Transport side FSM
      -----------------------------------------  
      nextSeqN    => (others => '0'),
      seqN          => (others => '0'),
      txHeaderAddr  => (others => '0'),
      txSegmentAddr => (others => '0'),
      txBufferAddr  => (others => '0'),
      
      --
      synH     => '0',      
      ackH     => '0',
      rstH     => '0',
      nullH    => '0',
      dataH    => '0',
      dataD    => '0',
      resend    => '0',
      
      --
      txRdy    => '0',      
      buffWe   => '0',
      buffSent => '0',
      chkEn    => '0',
      chkStb   => '0',
      
      -- SSI master 
      tspSsiMaster   => SSI_MASTER_INIT_C,
      tspSsiSlave    => SSI_SLAVE_NOTRDY_C,
      
      -- State Machine
      tspState     => INIT_S
   );

   signal r   : RegType := REG_INIT_C;
   signal rin : RegType;
   
begin

   ----------------------------------------------------------------------------------------------- 
   comb : process (r, rst_i, appSsiMaster_i, sndSyn_i, sndAck_i, connActive_i, sndRst_i, initSeqN_i, windowSize_i, headerRdy_i, ack_i, ackN_i,
                   sndResend_i, sndNull_i, tspSsiSlave_i, rdHeaderData_i, chksum_i, rdBuffData_i, chksumValid_i, headerLength_i) is
      
      variable v : RegType;

   begin
      v := r;
      
      -- /////////////////////////////////////////////////////////
      ------------------------------------------------------------
      -- Buffer window handling
      ------------------------------------------------------------   
      -- /////////////////////////////////////////////////////////
      
      
      ------------------------------------------------------------
      -- Buffer full if next slot is occupied
      if ( r.windowArray(conv_integer(r.nextSentAddr)).occupied = '1') then
         v.bufferFull := '1';
      else
         v.bufferFull := '0';
      end if;

      ------------------------------------------------------------
      -- Buffer empty if next unacknowledged slot is unoccupied
      if ( r.windowArray(conv_integer(r.firstUnackAddr)).occupied = '0') then
         v.bufferEmpty := '1';
      else
         v.bufferEmpty := '0';
      end if;
      
      ------------------------------------------------------------
      -- Write seqN and type to window array
      ------------------------------------------------------------
      if (r.buffWe = '1') then
         v.windowArray(conv_integer(r.nextSentAddr)).seqN    := r.nextSeqN;
         v.windowArray(conv_integer(r.nextSentAddr)).segType := r.rstH & r.nullH & r.dataH;
         v.windowArray(conv_integer(r.nextSentAddr)).occupied := '1';
         
         -- Update last sent address when new segment is being sent
         v.lastSentAddr := r.nextSentAddr;   
      else 
         v.windowArray      := r.windowArray;
      end if;
      
      ------------------------------------------------------------
      -- When buffer is sent increase nextSentAddr
      ------------------------------------------------------------
      if (r.buffSent = '1') then

         if r.nextSentAddr < (windowSize_i-1) then 
            v.nextSentAddr := r.nextSentAddr +1;
         else
            v.nextSentAddr := (others => '0');
         end if;
            
      else 
         v.nextSentAddr     := r.nextSentAddr;
      end if;
      
      
      -- /////////////////////////////////////////////////////////
      ------------------------------------------------------------
      -- ACK FSM
      -- Acknowledgment mechanism to increment firstUnackAddr
      -- Place out of order flags from EACK table
      ------------------------------------------------------------
      -- /////////////////////////////////////////////////////////
      
      case r.ackState is
         ----------------------------------------------------------------------
         when IDLE_S =>
         
            -- Hold ACK address
            v.firstUnackAddr := r.firstUnackAddr;
            v.lastAckSeqN    := r.lastAckSeqN;
            --v.eackAddr       := r.firstUnackAddr;
            --v.eackIndex      := 0;
            v.ackErr         := '0';
            
            
            -- Next state condition (TODO consider adding re_i = '0' if read should have priority)          
            if (ack_i = '1') then
               v.ackState    := ACK_S;
            end if;
         ----------------------------------------------------------------------
         when ACK_S =>
         
            -- If the same ackN received do nothing
            if  (r.lastAckSeqN = ackN_i) then
                v.firstUnackAddr  := r.firstUnackAddr;             
            -- Increment ACK address until seqN is found next received
            elsif r.firstUnackAddr < (windowSize_i-1) then
               v.windowArray(conv_integer(r.firstUnackAddr)).occupied := '0';            
               v.firstUnackAddr  := r.firstUnackAddr+1;
            else
               v.windowArray(conv_integer(r.firstUnackAddr)).occupied := '0';
               v.firstUnackAddr  := (others => '0');
            end if;
                       
            --v.eackAddr       := r.firstUnackAddr;
            -- v.eackIndex      := 0;
            v.ackErr         := '0';
            

            
            -- Next state condition            

            -- If the same ackN received
            if  (r.lastAckSeqN = ackN_i) then
           
                -- Go back to IDLE
                v.ackState   := IDLE_S;
            
            elsif (r.firstUnackAddr = r.lastSentAddr and r.windowArray(conv_integer(r.firstUnackAddr)).seqN /= ackN_i) then  
               -- If the acked seqN is not found go to error state
               v.ackState   := ERR_S;             
            elsif  (r.windowArray(conv_integer(r.firstUnackAddr)).seqN = ackN_i)  then
               v.lastAckSeqN := ackN_i; -- Save the last Acked seqN
               --if eack_i = '1' then
                  -- Go back to init when the acked seqN is found            
               --   v.ackState   := EACK_S;               
               --else
                  -- Go back to init when the acked seqN is found            
               v.ackState   := IDLE_S;
               --end if;
            end if;
         ----------------------------------------------------------------------
         -- when EACK_S =>
         
            -- -- Increment EACK address from firstUnackAddr to nextSentAddr
            -- if r.eackAddr < (windowSize_i-1) then 
               -- v.eackAddr  := r.eackAddr+1;
            -- else
               -- v.eackAddr  := (others => '0');
            -- end if;
            
            -- -- For every address check if the sequence number equals value from eackSeqnArr_i array.
            -- -- If it matches mark the eack field at the address and compare the next value from the table.          
            -- if  r.windowArray(conv_integer(r.eackAddr)).seqN = eackSeqnArr_i(r.eackIndex)  then
               -- v.windowArray(conv_integer(r.eackAddr)).eacked := '1';
               -- v.eackIndex := r.eackIndex + 1;               
            -- end if;
            
            -- v.firstUnackAddr  := r.firstUnackAddr;
            -- v.ackErr          := '0';
            
            -- -- Next state condition 
            -- if (r.eackAddr = r.nextSentAddr) then
               -- -- If the acked seqN is not found go to error state
               -- v.appState   := IDLE_S;
            -- end if;
         ----------------------------------------------------------------------
         when ERR_S =>
            -- Outputs
            v.firstUnackAddr := r.firstUnackAddr;
            --v.eackAddr       := r.firstUnackAddr;
            --v.eackIndex      := 0;
            v.ackErr         := '1';
            
            -- Next state condition            
            v.ackState   := IDLE_S;            
         ----------------------------------------------------------------------
         when others =>
             -- Outputs
            v.firstUnackAddr := r.firstUnackAddr;
            -- v.eackAddr       := r.firstUnackAddr;
            -- v.eackIndex      := 0;
            v.ackErr         := '1';

            -- Next state condition            
            v.ackState   := IDLE_S;            
      ----------------------------------------------------------------------
      end case;
      
      -- ///////////////////////////////////////////////////////// 
      ------------------------------------------------------------
      -- Application side FSM
      ------------------------------------------------------------
      -- /////////////////////////////////////////////////////////      
      
      -- Pipeline Master (DFF)
      v.appSsiMaster    := appSsiMaster_i;
      ------------------------------------------------------------
      case r.appState is
         ----------------------------------------------------------------------
         when IDLE_S =>
         
            -- SSI
            v.appSsiSlave := SSI_SLAVE_NOTRDY_C;
            
            -- Buffer write ctl
            v.rxSegmentAddr := (others =>'0');
            v.rxSegmentWe   := '0';

            -- txFSM
            v.sndData      := '0';
            v.lenErr      := '0';
            v.appBusy     := '0';
            
            -- Wait if buffer full
            if (r.bufferFull = '0') then
               v.appState    := WAIT_SOF_S;
            end if;
         ----------------------------------------------------------------------
         when WAIT_SOF_S =>
         
            -- SSI Ready to receive data from APP
            v.appSsiSlave := SSI_SLAVE_RDY_C;
            
            -- Buffer write ctl
            v.rxSegmentAddr := (others =>'0');
            v.rxSegmentWe   := '0';
            
            -- txFSM
            v.sndData     := '0';
            v.lenErr      := '0';
            v.appBusy     := '0';
            
            -- If other segment (NULL, or RST) is requested return to IDLE_S to
            -- check if buffer is still available (not full)
            if (r.buffWe = '1') then
               v.appState    := IDLE_S;
            -- Wait until receiving the first data            
            elsif (appSsiMaster_i.sof = '1' and appSsiMaster_i.valid = '1') then
               
               -- First data already received at this point
               v.rxSegmentAddr := r.rxSegmentAddr;
               v.appBusy     := '1';
               v.rxSegmentWe   := '1';
               
               -- Save SSI parameters
               v.windowArray(conv_integer(r.nextSentAddr)).dest   := appSsiMaster_i.dest;
               v.windowArray(conv_integer(r.nextSentAddr)).strb   := appSsiMaster_i.strb;
            
               v.appState    := SEG_RCV_S;
               
            -- If only one SSI word received (go directly to ready!)
            -- This is the case when both SOF and EOF are asserted.
            elsif (appSsiMaster_i.sof = '1' and appSsiMaster_i.valid = '1' and appSsiMaster_i.eof = '1' ) then
            
               -- First data already received at this point
               v.rxSegmentAddr := r.rxSegmentAddr;
               v.appBusy     := '1';
               v.rxSegmentWe   := '1';
            
               -- Save SSI parameters
               v.windowArray(conv_integer(r.nextSentAddr)).dest   := appSsiMaster_i.dest;
               v.windowArray(conv_integer(r.nextSentAddr)).strb   := appSsiMaster_i.strb;
               v.windowArray(conv_integer(r.nextSentAddr)).keep   := appSsiMaster_i.keep;
               
               v.windowArray(conv_integer(r.nextSentAddr)).eofe    := appSsiMaster_i.eofe;
               v.windowArray(conv_integer(r.nextSentAddr)).segSize := r.rxSegmentAddr(SEGMENT_ADDR_SIZE_C-1 downto 0); 
            
               v.appState    := SEG_RDY_S;
                        -- If one SSI word received
            end if;
         ----------------------------------------------------------------------
         when SEG_RCV_S =>
         
            -- SSI
            v.appSsiSlave := SSI_SLAVE_RDY_C;
                        
            -- Buffer write if data valid 
            if (appSsiMaster_i.valid = '1') then            
               v.rxSegmentAddr := r.rxSegmentAddr + 1;
               v.rxSegmentWe           := '1';
            else
               v.rxSegmentAddr := r.rxSegmentAddr;
               v.rxSegmentWe           := '0';             
            end if;
            
            -- txFSM
            v.sndData     := '0';
            v.lenErr      := '0';
            v.appBusy     := '1';            
            
            -- Wait until receiving EOF 
            if (appSsiMaster_i.eof = '1' and appSsiMaster_i.valid = '1') then
            
               -- Save packet eofe (error) and keep of last data word
               v.windowArray(conv_integer(r.nextSentAddr)).eofe   := appSsiMaster_i.eofe;
               v.windowArray(conv_integer(r.nextSentAddr)).keep   := appSsiMaster_i.keep;
               
               -- Save packet length (+1 because it has not incremented for EOF yet)
               v.windowArray(conv_integer(r.nextSentAddr)).segSize := r.rxSegmentAddr(SEGMENT_ADDR_SIZE_C-1 downto 0)+1;           

               v.appState    := SEG_RDY_S;        
            elsif (r.rxSegmentAddr(SEGMENT_ADDR_SIZE_C) = '1' ) then
               v.rxSegmentWe := '0';
               v.appState    := SEG_LEN_ERR;           
            end if;
         ----------------------------------------------------------------------            
         when SEG_RDY_S =>
            
            -- SSI
            v.appSsiSlave := SSI_SLAVE_NOTRDY_C;
            
            v.rxSegmentAddr := (others =>'0');
            v.rxSegmentWe   := '0';
            
            -- Request data at txFSM
            v.sndData     := '1';
            v.lenErr      := '0';
            v.appBusy     := '1';
            
            -- Hold request until accepted
            -- And not in resend process
            if (r.dataH = '1' and r.resend = '0' ) then
               v.appState    := WAIT_TX_S;
            end if;
         ----------------------------------------------------------------------
         when WAIT_TX_S => 
         
            -- SSI
            v.appSsiSlave := SSI_SLAVE_NOTRDY_C;
            
            v.rxSegmentAddr := (others =>'0');
            v.rxSegmentWe   := '0';
            
            -- Request data at txFSM
            v.sndData      := '0';
            v.lenErr      := '0';
            v.appBusy     := '1';
            
            -- Wait until txFSM sends the packet 
            if (r.txRdy = '1') then
               v.appState    := IDLE_S;
            end if;
         ----------------------------------------------------------------------
         when SEG_LEN_ERR => 
         
            -- SSI
            v.appSsiSlave := SSI_SLAVE_NOTRDY_C;
            -- Overflow happened (packet too big)            
            v.appSsiSlave.overflow   := '1';
            
            v.rxSegmentAddr := (others =>'0');
            v.rxSegmentWe   := '0';
            
            -- Request data at txFSM
            v.sndData      := '0';
            v.lenErr      := '1';
            v.appBusy     := '1';
            
            -- Go back to idle 
            v.appState    := IDLE_S;
         ----------------------------------------------------------------------
         when others =>
            -- Outs
            v := REG_INIT_C;

            -- Next state condition            
            v.appState   := IDLE_S;            
      ----------------------------------------------------------------------
      end case;
      
      
      -- ///////////////////////////////////////////////////////// 
      ------------------------------------------------------------      
      -- Initialisation of the parameters when the connection is broken
      -- TODO check
      if (connActive_i = '0') then
         v.firstUnackAddr := REG_INIT_C.firstUnackAddr;
         v.lastSentAddr   := REG_INIT_C.lastSentAddr;
         v.nextSentAddr   := REG_INIT_C.nextSentAddr;
         v.bufferFull     := REG_INIT_C.bufferFull;
         v.bufferEmpty    := REG_INIT_C.bufferEmpty;
         v.windowArray    := REG_INIT_C.windowArray;
         
         v.lastAckSeqN    := initSeqN_i;
         
         v.ackState    := REG_INIT_C.ackState;
         v.appState    := REG_INIT_C.appState;
      end if;
      ------------------------------------------------------------
      -- /////////////////////////////////////////////////////////       
      
      
      -- ///////////////////////////////////////////////////////// 
      ------------------------------------------------------------
      -- Transport side FSM
      ------------------------------------------------------------
      -- /////////////////////////////////////////////////////////  
      
      -- Reset flags 
      -- These flags will hold if not overidden
      v.tspSsiMaster:= SSI_MASTER_INIT_C;  
      if tspSsiSlave_i.ready = '1' then
         v.tspSsiMaster.valid := '0';
      else
         v.tspSsiMaster.valid := r.tspSsiMaster.valid;
      end if;
      
      -- Pipeline incomming slave
      v.tspSsiSlave:= tspSsiSlave_i;

      case r.tspState is
         ----------------------------------------------------------------------
         when INIT_S =>
            -- Counters
            v.nextSeqN    := initSeqN_i;
            v.seqN        := r.nextSeqN;
            
            v.txHeaderAddr  := (others => '0');
            v.txSegmentAddr := (others => '0');
             
            v.txBufferAddr := r.nextSentAddr;
            --
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := '0';
            v.nullH    := '0';
            v.dataH    := '0';
            v.dataD    := '0';
            --
            v.txRdy    := '1';
            v.buffWe   := '0';
            v.buffSent := '0';
            v.chkEn    := '0';
            v.chkStb    := '0';
            
           v.tspSsiMaster:= SSI_MASTER_INIT_C;  
           
            -- Next state condition   
            if    (sndSyn_i = '1') then
               v.tspState    := SYN_H_S;
            elsif (sndAck_i = '1') then
               v.tspState    := ACK_H_S;
            elsif (connActive_i = '1') then
               v.tspState      := CONN_S;
               -- Increase the sequence number to point to next seqN.
               --(This seqN will belong to the next Data, Null, or Rst segment).
               v.nextSeqN   := r.nextSeqN + 1;
            end if;
         ----------------------------------------------------------------------
         when CONN_S =>
            -- Counters 
            v.nextSeqN    := r.nextSeqN;
            v.seqN        := r.nextSeqN;
            
            v.txHeaderAddr  := (others => '0');
            v.txSegmentAddr := (others => '0');
             
            v.txBufferAddr := r.nextSentAddr;
            --
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := '0';
            v.nullH    := '0';       
            v.dataH    := '0';
            v.dataD    := '0';
            v.resend   := '0';
            
            --
            v.txRdy    := '1';
            v.buffWe   := '0';          
            v.buffSent := '0';
            v.chkEn    := '0';
            v.chkStb    := '0';
            
            v.tspSsiMaster:= SSI_MASTER_INIT_C;  
            
            -- Next state condition   
            if    (sndRst_i = '1' and r.bufferFull = '0' and r.appBusy = '0') then
               v.tspState    := RST_WE_S;
            elsif (r.sndData = '1' and r.bufferFull = '0') then
               v.tspState    := DATA_WE_S;
            elsif (sndResend_i = '1' and r.bufferEmpty = '0') then               
               v.tspState    := RESEND_INIT_S;
            elsif (sndAck_i = '1') then
               v.tspState    := ACK_H_S;  
            elsif (sndNull_i = '1' and r.bufferFull = '0' and r.appBusy = '0') then   
               v.tspState    := NULL_WE_S;         
            elsif (connActive_i = '0') then
               v.tspState    := INIT_S;
            end if;
          
         ----------------------------------------------------------------------
         -- SYN packet
         ----------------------------------------------------------------------
         when SYN_H_S =>
            -- Counters
            v.nextSeqN    := r.nextSeqN;
            v.seqN        := r.nextSeqN;
            
            v.txSegmentAddr := (others => '0');
            v.txBufferAddr := r.nextSentAddr;
            --
            v.synH     := '1';  -- Send SYN header
            v.ackH     := '0';
            v.rstH     := '0';
            v.nullH    := '0';       
            v.dataH    := '0';
            v.dataD    := '0';
            --
            v.txRdy    := '0';
            v.buffWe   := '0';
            v.buffSent := '0';
            v.chkEn    := '1';
            
            -- Leave initialised v.tspSsiMaster
            v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0) := rdHeaderData_i;

            -- Send SOF with header address 0
            if (r.txHeaderAddr = (r.txHeaderAddr'range => '0')) then
               v.tspSsiMaster.sof   := '1';
            else
               v.tspSsiMaster.sof   := '0';
            end if;
            
            -- Increment address and generate strobe
            if (r.tspSsiMaster.valid = '1' and tspSsiSlave_i.ready = '1' and headerRdy_i = '1') then
               v.txHeaderAddr        := r.txHeaderAddr + 1;
               v.chkStb              := '1';
            elsif (v.txHeaderAddr = headerLength_i-1 and headerRdy_i = '1') then
               v.txHeaderAddr        := r.txHeaderAddr;
               v.chkStb              := '1';
            else
               v.txHeaderAddr        := r.txHeaderAddr;
               v.chkStb              := '0';
            end if; 

            -- Next state condition
            -- End of header
            if (v.txHeaderAddr = headerLength_i-1) then
               v.tspSsiMaster.valid  := '0';
               -- Wait until checksum and Transport layer ready
               if (tspSsiSlave_i.ready = '1' and headerRdy_i = '1' and chksumValid_i = '1') then 
                  -- Add checksum to last 16 bits
                  v.tspSsiMaster.data(15 downto 0) := chksum_i;
                  v.tspSsiMaster.valid  := '1';                
                  v.tspSsiMaster.eof    := '1';
                  v.tspSsiMaster.eofe   := '0';

                  -- Next state            
                  v.tspState   := INIT_S;
               end if;
            -- Move data
            elsif (v.tspSsiMaster.valid = '0' and headerRdy_i = '1') then
               v.tspSsiMaster.valid  := '1';
            end if;

         ----------------------------------------------------------------------
         -- ACK packet
         ----------------------------------------------------------------------         
         when ACK_H_S =>
            -- Counters
            v.nextSeqN    := r.nextSeqN;
            v.seqN        := r.nextSeqN;
            
            v.txSegmentAddr := (others => '0');
            v.txBufferAddr  := r.nextSentAddr;
            v.txHeaderAddr  := (others => '0');
            
            --
            v.synH     := '0';
            v.ackH     := '1';  -- Send ack header
            v.rstH     := '0';
            v.nullH    := '0';       
            v.dataH    := '0';
            v.dataD    := '0';
            --
            v.txRdy    := '0';
            v.buffWe   := '0';          
            v.buffSent := '0';
            v.chkEn    := '1';
            
            if (headerRdy_i = '1') then
               v.chkStb   := '1';
            end if;
            
            -- Leave initialised v.tspSsiMaster
            v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0) := rdHeaderData_i;
            
            -- Next state condition
            if (chksumValid_i = '1' and v.tspSsiMaster.valid = '0' ) then -- Frame size is one word
               v.tspSsiMaster.valid  := '1';
               v.tspSsiMaster.sof    := '1';
               v.tspSsiMaster.strb   := (others => '1');
               v.tspSsiMaster.keep   := (others => '1');
               v.tspSsiMaster.dest   := (others => '0');
               v.tspSsiMaster.eof    := '1';
               v.tspSsiMaster.eofe   := '0';
               v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0) := rdHeaderData_i;
               v.tspSsiMaster.data(15 downto 0) := chksum_i; -- Add header to last two bytes
                
               --                
               if  connActive_i = '0' then          
                  v.tspState   := INIT_S; 
               else
                  v.tspState   := CONN_S; 
               end if;
               
            end if;

         ----------------------------------------------------------------------
         -- RST packet
         ----------------------------------------------------------------------         
         when RST_WE_S =>
            -- Counters
            v.nextSeqN    := r.nextSeqN;
            v.seqN        := r.nextSeqN;
            
            v.txHeaderAddr  := (others => '0');
            v.txSegmentAddr := (others => '0');
             
            v.txBufferAddr := r.nextSentAddr;
            -- State control signals 
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := '1';  -- Send reset header 
            v.nullH    := '0';       
            v.dataH    := '0';
            v.dataD    := '0';
            -- 
            v.txRdy    := '0';
            v.buffWe   := '1';  -- Update buffer seqN and Type
            v.buffSent := '0';
            v.chkEn    := '0';
            v.chkStb   := '0';
            
            -- SSI master 
            -- Leave initialised v.tspSsiMaster
            v.tspSsiMaster.data := r.tspSsiMaster.data;
            
            -- Next State condition
            v.tspState   := RST_H_S;
         ----------------------------------------------------------------------
         when RST_H_S =>
          -- 
            v.nextSeqN    := r.nextSeqN;
            v.seqN        := r.nextSeqN;

            v.txSegmentAddr := (others => '0');
            v.txBufferAddr := r.nextSentAddr;
            v.txHeaderAddr  := (others => '0');
            
            -- Flags
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := '1';  -- Send reset header 
            v.nullH    := '0';       
            v.dataH    := '0';
            v.dataD    := '0';
            --
            v.txRdy    := '0';
            v.buffWe   := '0';          
            v.buffSent := '0';
            v.chkEn    := '1';
            
            if (headerRdy_i = '1') then
               v.chkStb   := '1';
            end if;
            
            -- Leave initialised v.tspSsiMaster
            v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0) := rdHeaderData_i;
            
            -- Next state condition
            if (chksumValid_i = '1' and v.tspSsiMaster.valid = '0' ) then -- Frame size is one word
               v.tspSsiMaster.valid  := '1';
               v.tspSsiMaster.sof    := '1';
               v.tspSsiMaster.strb   := (others => '1');
               v.tspSsiMaster.keep   := (others => '1');
               v.tspSsiMaster.dest   := (others => '0');
               v.tspSsiMaster.eof    := '1';
               v.tspSsiMaster.eofe   := '0';
               v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0) := rdHeaderData_i;
               v.tspSsiMaster.data(15 downto 0) := chksum_i; -- Add header to last two bytes
                
               -- Increment seqN
               v.nextSeqN    := r.nextSeqN+1; -- Increment SEQ number at the end of segment transmission
               v.seqN        := r.nextSeqN+1;
               v.buffSent    := '1';          -- Increment the sent buffer
               v.tspState   := CONN_S;
            --
            end if;           

         ----------------------------------------------------------------------
         -- NULL packet
         ----------------------------------------------------------------------         
         when NULL_WE_S =>
            -- Counters
            v.nextSeqN    := r.nextSeqN;
            v.seqN        := r.nextSeqN;
            
            v.txHeaderAddr  := (others => '0');
            v.txSegmentAddr := (others => '0');
             
            v.txBufferAddr := r.nextSentAddr;
            
            -- State control signals 
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := '0';   
            v.nullH    := '1';  -- Send null header     
            v.dataH    := '0';
            v.dataD    := '0';
            -- 
            v.txRdy    := '0';
            v.buffWe   := '1';  -- Update buffer seqN and Type 
            v.buffSent := '0';
            v.chkEn    := '0';
            v.chkStb   := '0';
            
            -- SSI master 
            -- Leave initialised v.tspSsiMaster
            
            -- Next State condition
            v.tspState   := NULL_H_S;
         ----------------------------------------------------------------------
         when NULL_H_S =>
            -- Counters
            v.nextSeqN    := r.nextSeqN;
            v.seqN        := r.nextSeqN;
            v.txHeaderAddr  := (others => '0');
            
            v.txSegmentAddr := (others => '0');
            v.txBufferAddr := r.nextSentAddr;
            
            -- Flags
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := '0';  
            v.nullH    := '1';  -- Send null header 
            v.dataH    := '0';
            v.dataD    := '0';
            --
            v.txRdy    := '0';
            v.buffWe   := '0';          
            v.buffSent := '0';
            v.chkEn    := '1';
            
            if (headerRdy_i = '1') then
               v.chkStb   := '1';
            end if;
            
            -- Leave initialised v.tspSsiMaster
            v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0) := rdHeaderData_i;
            
            -- Next state condition
            if (chksumValid_i = '1' and v.tspSsiMaster.valid = '0' ) then -- Frame size is one word
               v.tspSsiMaster.valid  := '1';
               v.tspSsiMaster.sof    := '1';
               v.tspSsiMaster.strb   := (others => '1');
               v.tspSsiMaster.keep   := (others => '1');
               v.tspSsiMaster.dest   := (others => '0');
               v.tspSsiMaster.eof    := '1';
               v.tspSsiMaster.eofe   := '0';
               v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0) := rdHeaderData_i;
               v.tspSsiMaster.data(15 downto 0) := chksum_i; -- Add header to last two bytes
               
               -- Increment seqN
               v.nextSeqN    := r.nextSeqN+1; -- Increment SEQ number at the end of segment transmission
               v.seqN        := r.nextSeqN+1;
               v.buffSent    := '1';          -- Increment the sent buffer
               v.tspState   := CONN_S;
            end if;
            
         ----------------------------------------------------------------------
         -- DATA packet
         ----------------------------------------------------------------------         
         when DATA_WE_S =>
            -- Counters
            v.nextSeqN    := r.nextSeqN;
            v.seqN        := r.nextSeqN;
            
            v.txHeaderAddr  := (others => '0');
            v.txSegmentAddr := (others => '0');
             
            v.txBufferAddr := r.nextSentAddr;
            
            -- State control signals 
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := '0';   
            v.nullH    := '0';      
            v.dataH    := '1';  -- Send data header 
            v.dataD    := '0';
            -- 
            v.txRdy    := '0';
            v.buffWe   := '1';  -- Update buffer seqN and Type 
            v.buffSent := '0';
            v.chkEn    := '0';
            v.chkStb   := '0';
            
            -- SSI master 
            -- Leave initialised v.tspSsiMaster
            v.tspSsiMaster.data := r.tspSsiMaster.data;
            
            -- Next state condition
            v.tspState   := DATA_H_S;
         ----------------------------------------------------------------------
         when DATA_H_S =>
            -- Counters
            v.nextSeqN    := r.nextSeqN;
            v.seqN        := r.nextSeqN;
            
            v.txSegmentAddr := (others => '0');
            v.txBufferAddr  := r.nextSentAddr;
            --
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := '0';  
            v.nullH    := '0';  
            v.dataH    := '1';  -- Send data header 
            v.dataD    := '0';
            --
            v.txRdy    := '0';
            v.buffWe   := '0';          
            v.buffSent := '0';
            v.chkEn    := '1';
            
            -- if header data ready than
            -- strobe the checksum       
            if (headerRdy_i = '1') then
               v.chkStb   := '1';
            end if;
            
            v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0) := rdHeaderData_i;
            
            -- Next state condition
            -- Frame size is one word
            -- Wait for the chksum to be ready
            if (v.tspSsiMaster.valid = '0' and tspSsiSlave_i.ready = '1' and chksumValid_i = '1') then
               v.tspSsiMaster.valid  := '1';  
               v.tspSsiMaster.sof    := '1';
               v.tspSsiMaster.strb   := r.windowArray(conv_integer(r.txBufferAddr)).strb;
               v.tspSsiMaster.dest   := r.windowArray(conv_integer(r.txBufferAddr)).dest;
               v.tspSsiMaster.eof    := '0';
               v.tspSsiMaster.eofe   := '0';
               v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0) := rdHeaderData_i;
               v.tspSsiMaster.data(15 downto 0) := chksum_i; -- Add header to last two bytes

               v.tspState := DATA_S;
               --
            end if;            
                 ----------------------------------------------------------------------
         when DATA_S =>
            -- Counters
            v.nextSeqN    := r.nextSeqN;
            v.seqN        := r.nextSeqN;
            
            v.txHeaderAddr  := (others => '0');            
            v.txBufferAddr  := r.nextSentAddr;
            v.txSegmentAddr := r.txSegmentAddr;
            
            --
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := '0';  
            v.nullH    := '0';  
            v.dataH    := '0';   
            v.dataD    := '1';  -- Send data
            --
            v.txRdy    := '0';
            v.buffWe   := '0';          
            v.buffSent := '0';
            v.chkEn    := '0';
            v.chkStb   := '0';
            
            -- Other SSI parameters
            v.tspSsiMaster.sof    := '0';
            v.tspSsiMaster.strb   := r.windowArray(conv_integer(r.txBufferAddr)).strb;
            v.tspSsiMaster.dest   := r.windowArray(conv_integer(r.txBufferAddr)).dest;           
            v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0)  := rdBuffData_i;
            
            -- Move data
            -- Retract the valid if one clock cycle before there was no ready
            -- This enables data to be ready on time.
            if (v.tspSsiMaster.valid = '0' and r.tspSsiSlave.ready = '1') then
               v.tspSsiMaster.valid  := '1';          
            end if;
            
            -- Next state condition
            if  (v.tspSsiMaster.valid = '1' and 
                 r.txSegmentAddr >= r.windowArray(conv_integer(r.txBufferAddr)).segSize) then

               -- Send EOF at the end of the segment
               v.tspSsiMaster.eof    := '1';
               v.tspSsiMaster.keep   := r.windowArray(conv_integer(r.txBufferAddr)).keep;
               v.tspSsiMaster.eofe   := r.windowArray(conv_integer(r.txBufferAddr)).eofe;
               v.txSegmentAddr       := r.txSegmentAddr;               
               --
               v.tspState   := DATA_SENT_S;

            -- Increment segment address only when Slave do not increase address first time
            elsif (r.tspSsiMaster.sof = '0' and tspSsiSlave_i.ready = '1') then
               v.txSegmentAddr       := r.txSegmentAddr + 1;
            end if;
            
         -----------------------------------------------------------------------------   
         when DATA_SENT_S =>
             -- Outputs
            v.nextSeqN    := r.nextSeqN+1; -- Increment SEQ number at the end of segment transmission
            v.seqN        := r.nextSeqN+1;
            
            v.txHeaderAddr  := (others => '0');
            v.txSegmentAddr := (others => '0');
             
            v.txBufferAddr := r.nextSentAddr;
            --
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := '0';
            v.nullH    := '0';       
            v.dataH    := '0';
            v.dataD    := '0';
            v.chkEn    := '0';
            v.chkStb   := '0';
            --
            v.txRdy    := '0';
            v.buffWe   := '0';         
            v.buffSent := '1';     -- Increment buffer last sent address(txBuffer)
            
            -- SSI master (Initialise - stop transmission) 
            v.tspSsiMaster         := SSI_MASTER_INIT_C;
            
            -- Next state
            v.tspState   := CONN_S;

         ----------------------------------------------------------------------
         -- Resend all packets from the buffer
         -- Packets between r.firstUnackAddr and r.lastSentAddr
         ----------------------------------------------------------------------            
         when RESEND_INIT_S =>
            -- Start from first unack address 
            v.txBufferAddr := r.firstUnackAddr;

            -- Counters
            v.nextSeqN    := r.nextSeqN; -- Never increment seqN while resending 
            v.seqN        := r.windowArray(conv_integer(r.txBufferAddr)).seqN;
            
            v.txHeaderAddr  := (others => '0');
            v.txSegmentAddr := (others => '0');

            -- State control signals 
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := '0';
            v.nullH    := '0';
            v.dataH    := '0';
            v.dataD    := '0';
            -- 
            v.txRdy    := '0';
            v.buffWe   := '0'; 
            v.buffSent := '0';
            v.chkEn    := '0';
            v.chkStb   := '0';

            -- SSI master 
            v.tspSsiMaster := SSI_MASTER_INIT_C;
            
            -- Next state condition
            v.tspState   := RESEND_S;
           
         when RESEND_S =>
            -- Start from first unack address 
            v.txBufferAddr := r.txBufferAddr;

            -- Counters
            v.nextSeqN    := r.nextSeqN; -- Never increment seqN while resending 
            v.seqN        := r.windowArray(conv_integer(r.txBufferAddr)).seqN;
            
            v.txHeaderAddr  := (others => '0');
            v.txSegmentAddr := (others => '0');

            -- State control signals 
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := r.windowArray(conv_integer(r.txBufferAddr)).segType(2);  
            v.nullH    := r.windowArray(conv_integer(r.txBufferAddr)).segType(1);  
            v.dataH    := r.windowArray(conv_integer(r.txBufferAddr)).segType(0);
            v.dataD    := '0';
            v.resend   := '1';
            -- 
            v.txRdy    := '0';
            v.buffWe   := '0'; 
            v.buffSent := '0';
            v.chkEn    := '0';
            v.chkStb   := '0';

            -- SSI master 
            v.tspSsiMaster := SSI_MASTER_INIT_C;
            
            -- Next State condition
            v.tspState   := RESEND_H_S;   
   
         ----------------------------------------------------------------------
         when RESEND_H_S =>
            -- Counters
            v.nextSeqN    := r.nextSeqN; -- Never increment seqN while resending
            v.seqN        := r.windowArray(conv_integer(r.txBufferAddr)).seqN;
            
            v.txSegmentAddr := (others => '0');
            v.txBufferAddr  := r.txBufferAddr;
            --
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := r.windowArray(conv_integer(r.txBufferAddr)).segType(2);  
            v.nullH    := r.windowArray(conv_integer(r.txBufferAddr)).segType(1);  
            v.dataH    := r.windowArray(conv_integer(r.txBufferAddr)).segType(0); 
            v.dataD    := '0';
            v.resend   := '1';
            --
            v.txRdy    := '0';
            v.buffWe   := '0';          
            v.buffSent := '0';
            v.chkEn    := '1';
            
            -- if header data ready than
            -- strobe the checksum       
            if (headerRdy_i = '1') then
               v.chkStb   := '1';
            end if;
            
            v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0) := rdHeaderData_i;
            
            -- Next state condition
            -- Frame size is one word
            -- Wait for the chksum to be ready
            if (v.tspSsiMaster.valid = '0' and tspSsiSlave_i.ready = '1' and chksumValid_i = '1') then
               v.tspSsiMaster.sof    := '1';
               v.tspSsiMaster.valid  := '1';
               v.tspSsiMaster.strb   := r.windowArray(conv_integer(r.txBufferAddr)).strb;
               v.tspSsiMaster.dest   := r.windowArray(conv_integer(r.txBufferAddr)).dest;
               v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0) := rdHeaderData_i;
               v.tspSsiMaster.data(15 downto 0) := chksum_i; -- Add header to last two bytes
               
               -- Null or Rst packet
               if    (r.windowArray(conv_integer(r.txBufferAddr)).segType(2) = '1' or
                      r.windowArray(conv_integer(r.txBufferAddr)).segType(1) = '1'
               ) then 

               -- Send EOF and start sending next packet                            
                  v.tspSsiMaster.eof    := '1';
                  v.tspSsiMaster.eofe   := '0';
                  --
                  v.tspState := RESEND_PP_S;

               -- If DATA packet start sending data
               else
                  v.tspState := RESEND_DATA_S;
               end if;
            end if;               
         ----------------------------------------------------------------------         
         when RESEND_DATA_S =>
            -- Counters
            v.nextSeqN    := r.nextSeqN; -- Never increment seqN while resending
            v.seqN        := r.windowArray(conv_integer(r.txBufferAddr)).seqN;
            
            v.txHeaderAddr  := (others => '0');            
            v.txBufferAddr  := r.txBufferAddr;
            v.txSegmentAddr := r.txSegmentAddr;
            
            --
            v.synH     := '0';
            v.ackH     := '0';
            v.rstH     := '0';  
            v.nullH    := '0';  
            v.dataH    := '0';   
            v.dataD    := '1';  -- Send data
            v.resend   := '1';            

            --
            v.txRdy    := '0';
            v.buffWe   := '0';          
            v.buffSent := '0';
            v.chkEn    := '0';
            v.chkStb   := '0';
            
            -- SSI Control
             
            -- Other SSI parameters
            v.tspSsiMaster.sof    := '0';
            v.tspSsiMaster.strb   := r.windowArray(conv_integer(r.txBufferAddr)).strb;
            v.tspSsiMaster.dest   := r.windowArray(conv_integer(r.txBufferAddr)).dest;
            v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0)  := rdBuffData_i;
            
            -- Move data
            -- Retract the valid if one clock cycle before there was no ready
            -- This enables data to be ready on time.
            if (v.tspSsiMaster.valid = '0' and r.tspSsiSlave.ready = '1') then
               v.tspSsiMaster.valid  := '1';          
            end if;

            -- Next state condition
            if  (v.tspSsiMaster.valid = '1' and
                r.txSegmentAddr >= r.windowArray(conv_integer(r.txBufferAddr)).segSize) then

               -- Send EOF at the end of the segment
               v.tspSsiMaster.eof    := '1';
               v.tspSsiMaster.keep   := r.windowArray(conv_integer(r.txBufferAddr)).keep;
               v.tspSsiMaster.eofe   := r.windowArray(conv_integer(r.txBufferAddr)).eofe;
               v.txSegmentAddr       := r.txSegmentAddr;               
               -- 
               v.tspState   := RESEND_PP_S;
               
            -- Increment segment address only when Slave is ready
            elsif (r.tspSsiMaster.sof = '0' and tspSsiSlave_i.ready = '1') then
               v.txSegmentAddr       := r.txSegmentAddr + 1;
            end if;
         ----------------------------------------------------------------------            
         when RESEND_PP_S =>
            -- Counters
            v.nextSeqN    := r.nextSeqN; -- Never increment seqN while resending 
            v.seqN        := r.windowArray(conv_integer(r.txBufferAddr)).seqN;
            
            v.txHeaderAddr  := (others => '0');
            v.txSegmentAddr := (others => '0');
            
            -- Increment buffer address (circulary)
            if r.txBufferAddr < (windowSize_i-1) then
               v.txBufferAddr := r.txBufferAddr+1;
            else
               v.txBufferAddr := (others => '0');
            end if;
            
            -- State control signals 
            v.rstH     := '0'; 
            v.nullH    := '0';  
            v.dataH    := '0';  
            v.nullH    := '0';      
            v.dataH    := '0'; 
            v.dataD    := '0';
            v.resend   := '1';
            
            -- 
            v.txRdy    := '0';
            v.buffWe   := '0'; 
            v.buffSent := '0';
            v.chkEn    := '0';
            v.chkStb   := '0';

            -- SSI master 
            v.tspSsiMaster := SSI_MASTER_INIT_C;
            
            -- Different if DATA segment is sent or NULL or RST
            if (r.windowArray(conv_integer(r.txBufferAddr)).segType(0) = '1') then
               v.tspSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0)  := rdBuffData_i;
            else
               v.tspSsiMaster.data  := r.tspSsiMaster.data;
            end if;
            
            -- Next state condition
            -- Go back to CONN_S when the last sent address reached 
            if (r.txBufferAddr = r.lastSentAddr) then
               v.tspState   := CONN_S;        
            else
               v.tspState   := RESEND_S;
            end if;
         ----------------------------------------------------------------------
         when others =>
            --
            v := REG_INIT_C;         
      ----------------------------------------------------------------------
      end case;
      
      -- Synchronous Reset
      if (rst_i = '1') then
         v := REG_INIT_C;
      end if;
      
      rin <= v;
      -----------------------------------------------------------
      ---------------------------------------------------------------------
      -- APP side
      
      -- Combine ram write address      
      wrBuffAddr_o <= r.nextSentAddr & r.rxSegmentAddr(SEGMENT_ADDR_SIZE_C-1 downto 0);
      wrBuffData_o <= r.AppSsiMaster.data(RSSI_WORD_WIDTH_C*8-1 downto 0);
      wrBuffWe_o   <= r.rxSegmentWe;
      
      -- Slave out immediately
      appSsiSlave_o <= v.appSsiSlave;
      
      -- Errors
      ackErr_o <= r.ackErr;
      lenErr_o <= r.lenErr;

      -----------------------------------------------------------
      ---------------------------------------------------------------------      
      -- TSP side
      
      -- Combine ram read address
      rdBuffAddr_o     <= v.txBufferAddr & v.txSegmentAddr(SEGMENT_ADDR_SIZE_C-1 downto 0);
      rdHeaderAddr_o   <= v.txHeaderAddr;      

      -- State assignment
      synHeadSt_o  <= r.synH;
      ackHeadSt_o  <= r.ackH;
      dataHeadSt_o <= r.dataH;
      dataSt_o     <= r.dataD;
      rstHeadSt_o  <= r.rstH;
      nullHeadSt_o <= r.nullH;
      
      chksumEnable_o <= r.chkEn;
      chksumStrobe_o <= r.chkStb;
           
      -- Sequence number from buffer
      txSeqN_o       <= r.seqN;
      tspSsiMaster_o <= r.tspSsiMaster;
      
      -- 
      lastAckN_o <= r.lastAckSeqN;
   --------------------------------------------------------------------- 
   end process comb;

   seq : process (clk_i) is
   begin
      if (rising_edge(clk_i)) then
         r <= rin after TPD_G;
      end if;
   end process seq;
 

 
   
   ---------------------------------------------------------------------
end architecture rtl;