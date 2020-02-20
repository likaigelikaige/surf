#-----------------------------------------------------------------------------
# Title      : PyRogue AMC Carrier core's Non-volatile memory (100k endurance)
#-----------------------------------------------------------------------------
# Description:
# PyRogue AMC Carrier core's Non-volatile memory (100k endurance)
#-----------------------------------------------------------------------------
# This file is part of the 'SLAC Firmware Standard Library'. It is subject to
# the license terms in the LICENSE.txt file found in the top-level directory
# of this distribution and at:
#    https://confluence.slac.stanford.edu/display/ppareg/LICENSE.html.
# No part of the 'SLAC Firmware Standard Library', including this file, may be
# copied, modified, propagated, or distributed except according to the terms
# contained in the LICENSE.txt file.
#-----------------------------------------------------------------------------

import pyrogue as pr

class Axi24LC64FT(pr.Device):
    def __init__(self,
                 nelms       = 0x800,
                 instantiate = True,
                 **kwargs):
        
        super().__init__(**kwargs)

        ##############################
        # Variables
        ##############################
        if (instantiate):
            pr.MemoryDevice(
                name        = "Mem",
                description = "Memory Array",
                size        = (4*nelms),
                # nelms     = nelms,
            )
