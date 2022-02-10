-------------------------------------------------------------------------------
-- Title      : SUGOI Protocol: https://confluence.slac.stanford.edu/x/3of_E
-------------------------------------------------------------------------------
-- Company    : SLAC National Accelerator Laboratory
-------------------------------------------------------------------------------
-- Description: Top-level for ASIC side
-------------------------------------------------------------------------------
-- This file is part of 'SLAC Firmware Standard Library'.
-- It is subject to the license terms in the LICENSE.txt file found in the
-- top-level directory of this distribution and at:
--    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
-- No part of 'SLAC Firmware Standard Library', including this file,
-- may be copied, modified, propagated, or distributed except according to
-- the terms contained in the LICENSE.txt file.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

library surf;
use surf.StdRtlPkg.all;
use surf.AxiLitePkg.all;

entity SugoiAsicCore is
   generic (
      TPD_G : time := 1 ns);
   port (
      -- Clock and Reset
      clk             : in  sl;
      rst             : out sl;               -- Active HIGH global reset
      rstL            : out sl;               -- Active LOW global reset
      -- SUGOI Serial Ports
      rx              : in  sl;               -- serial rate = clk frequency
      tx              : out sl;               -- serial rate = clk frequency
      -- Link Status
      linkup          : out sl;
      -- Trigger/Timing Command Bus
      opCode          : out slv(7 downto 0);  -- 1-bit per Control code
      -- AXI-Lite Master Interface
      axilReadMaster  : out AxiLiteReadMasterType;
      axilReadSlave   : in  AxiLiteReadSlaveType;
      axilWriteMaster : out AxiLiteWriteMasterType;
      axilWriteSlave  : in  AxiLiteWriteSlaveType);
end entity SugoiAsicCore;

architecture mapping of SugoiAsicCore is

   signal rxEncodeValid : sl;
   signal rxEncodeData  : slv(9 downto 0);
   signal rxSlip        : sl;

   signal rxDecodeValid : sl;
   signal rxDecodeData  : slv(9 downto 0);
   signal rxDecodeDataK : sl;
   signal rxCodeErr     : sl;
   signal rxDispErr     : sl;
   signal rxError       : sl;

   signal txDecodeValid : sl;
   signal txDecodeData  : slv(9 downto 0);
   signal txDecodeDataK : sl;

   signal txEncodeValid : sl;
   signal txEncodeData  : slv(9 downto 0);

begin

   ---------------
   -- 1:10 Gearbox
   ---------------
   U_Deserializer : entity surf.Gearbox
      generic map (
         TPD_G          => TPD_G,
         SLAVE_WIDTH_G  => 1,
         MASTER_WIDTH_G => 10)
      port map (
         -- Clock and Reset
         clk          => clk,
         rst          => '0',           -- Never reset on global reset command
         -- Slip Interface
         slip         => rxSlip,
         -- Slave Interface
         slaveData(0) => rx,
         -- Master Interface
         masterValid  => rxEncodeValid,
         masterData   => rxEncodeData);

   ----------------
   -- 8B10B Decoder
   ----------------
   U_Decode : entity surf.Decoder8b10b
      generic map (
         TPD_G       => TPD_G,
         NUM_BYTES_G => 1)
      port map (
         -- Clock and Reset
         clk        => clk,
         rst        => '0',             -- Never reset on global reset command
         -- Encoded Interface
         validIn    => rxEncodeValid,
         dataIn     => rxEncodeData,
         -- Encoded Interface
         validOut   => rxDecodeValid,
         dataOut    => rxDecodeData,
         dataKOut   => rxDecodeDataK,
         codeErr(0) => rxCodeErr,
         dispErr(0) => rxDispErr);

   rxError <= rxCodeErr or rxDispErr;

   -------------
   -- FSM Module
   -------------
   U_Fsm : entity surf.SugoiAsicFsm
      generic map (
         TPD_G => TPD_G)
      port map (
         -- Clock and Reset
         clk             => clk,
         rst             => rst,
         rstL            => rstL,
         -- Link Status
         linkup          => linkup,
         -- Trigger/Timing Command Bus
         opCode          => opCode,
         -- RX Interface
         rxValid         => rxDecodeValid,
         rxData          => rxDecodeData,
         rxDataK         => rxDecodeDataK,
         rxError         => rxError,
         rxSlip          => rxSlip,
         -- TX Interface
         txValid         => txDecodeValid,
         txData          => txDecodeData,
         txDataK         => txDecodeDataK,
         -- AXI-Lite Master Interface
         axilReadMaster  => axilReadMaster,
         axilReadSlave   => axilReadSlave,
         axilWriteMaster => axilWriteMaster,
         axilWriteSlave  => axilWriteSlave);

   ----------------
   -- 8B10B Encoder
   ----------------
   U_Encode : entity surf.Encoder8b10b
      generic map (
         TPD_G       => TPD_G,
         NUM_BYTES_G => 1)
      port map (
         -- Clock and Reset
         clk      => clk,
         rst      => '0',               -- Never reset on global reset command
         -- Decoded Interface
         validIn  => txDecodeValid,
         dataIn   => txDecodeData,
         dataKIn  => txDecodeDataK,
         -- Encoded Interface
         validOut => txEncodeValid,
         dataOut  => txEncodeData);

   ---------------
   -- 10:1 Gearbox
   ---------------
   U_Serializer : entity surf.Gearbox
      generic map (
         TPD_G          => TPD_G,
         SLAVE_WIDTH_G  => 1,
         MASTER_WIDTH_G => 10)
      port map (
         -- Clock and Reset
         clk           => clk,
         rst           => '0',          -- Never reset on global reset command
         -- Slave Interface
         slaveValid    => txEncodeValid,
         slaveData     => txEncodeData,
         -- Master Interface
         masterData(0) => tx);

end mapping;
