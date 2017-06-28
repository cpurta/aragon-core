pragma solidity ^0.4.11;

import "../Application.sol";
import "../../kernel/Kernel.sol";

import "./BylawOracle.sol";
import "../Application.sol";

import "../status/StatusApp.sol";
import "../ownership/OwnershipApp.sol";
import "../capital/CapitalApp.sol";

contract IVotingApp {
  function getStatusForVoteAddress(address addr) constant returns (uint state, address voteCreator, address voteAddress, uint64 voteCreatedBlock, uint64 voteStartsBlock, uint64 voteEndsBlock, uint256 yays, uint256 nays, uint256 totalQuorum);
}

contract IBylawsApp {
  event BylawChanged(bytes4 sig, uint8 bylawType);
}

contract BylawsApp is IBylawsApp, Application, PermissionsOracle {
  enum BylawType { Voting, Status, SpecialStatus, Address, Oracle, Combinator }
  enum CombinatorType { Or, And, Xor }

  struct Bylaw {
    BylawType bylawType;

    bool not; // reverse logic

    // a bylaw can be one of these types
    uint8 status; // For status and special status types
    address addr; // For address and oracle types
    VotingBylaw voting;
    CombinatorBylaw combinator;
  }

  struct VotingBylaw {
    uint256 supportPct;       // 16pct % * 10^16 (pe. 5% = 5 * 10^16)
    uint256 minQuorumPct;     // 16pct

    uint64 minimumDebateTime; // in blocks
    uint64 minimumVotingTime; // in blocks
  }

  struct CombinatorBylaw {
    CombinatorType combinatorType; // if TRUE combinator is AND, if false is an OR combinator
    uint256 leftBylawId;
    uint256 rightBylawId;
  }

  Bylaw[] bylaws;
  mapping (bytes4 => uint) bylawEntrypoint;

  uint constant pctBase = 10 ** 18;

  function BylawsApp(address dao)
           Application(dao) {
    newBylaw(); // so index is 1 for first legit bylaw
  }

  function canHandlePayload(bytes payload) constant returns (bool) {
    return true;
  }

  function newBylaw() internal returns (uint id, Bylaw storage newBylaw) {
    id = bylaws.length;
    bylaws.length++;
    newBylaw = bylaws[id];
  }

  // @dev Links a signature entry point to a bylaw.
  // @dev It is the only function that needs to be protected as it
  // @dev a nice side effect is that multiple actions can share the same bylaw
  function linkBylaw(bytes4 sig, uint id) onlyDAO {
    require(id < bylaws.length);
    bylawEntrypoint[sig] = id;

    BylawChanged(sig, getBylawType(id));
  }

  function setStatusBylaw(bytes4 sig, uint8 statusNeeded, bool isSpecialStatus) {
    var (id, bylaw) = newBylaw();

    bylaw.bylawType = isSpecialStatus ? BylawType.SpecialStatus : BylawType.Status;
    bylaw.status = statusNeeded;

    linkBylaw(sig, id);
  }

  function setAddressBylaw(bytes4 sig, address addr, bool isOracle) {
    var (id, bylaw) = newBylaw();

    bylaw.bylawType = isOracle ? BylawType.Oracle : BylawType.Address;
    bylaw.addr = addr;

    linkBylaw(sig, id);
  }

  function setVotingBylaw(bytes4 sig, uint256 supportPct, uint256 minQuorumPct, uint64 minimumDebateTime, uint64 minimumVotingTime) {
    var (id, bylaw) = newBylaw();

    require(supportPct > 0 && supportPct <= pctBase); // dont allow weird cases

    bylaw.bylawType = BylawType.Voting;
    bylaw.voting.supportPct = supportPct;
    bylaw.voting.minQuorumPct = minQuorumPct;
    bylaw.voting.minimumDebateTime = minimumDebateTime;
    bylaw.voting.minimumVotingTime = minimumVotingTime;

    linkBylaw(sig, id);
  }

  function getBylawType(uint bylawId) constant returns (uint8) {
    return uint8(bylaws[bylawId].bylawType);
  }

  // Permissions Oracle compatibility
  function canPerformAction(address sender, address token, uint256 value, bytes data) constant returns (bool) {
    return canPerformAction(getSig(data), sender, data, token, value);
  }

  function performedAction(address sender, address token, uint256 value, bytes data) {}

  function canPerformAction(bytes4 sig, address sender, bytes data, address token, uint256 value) returns (bool) {
    uint bylawId = bylawEntrypoint[sig];

    // not existent bylaw, always allow action.
    if (bylawId == 0) return true;

    return canPerformAction(bylawId, sender, data, token, value);
  }

  function canPerformAction(uint bylawId, address sender, bytes data, address token, uint256 value) internal returns (bool) {
    Bylaw storage bylaw = bylaws[bylawId];
    if (bylaw.bylawType == BylawType.SpecialStatus) {
      return negateIfNeeded(isSpecialStatus(sender, bylaw.status), bylaw.not);
    }

    if (bylaw.bylawType == BylawType.Status) {
      return negateIfNeeded(getStatus(sender) >= bylaw.status, bylaw.not);
    }

    if (bylaw.bylawType == BylawType.Address) {
      return negateIfNeeded(sender == bylaw.addr, bylaw.not);
    }

    if (bylaw.bylawType == BylawType.Oracle) {
      // var (canPerform,) = BylawOracle(b.addr).canPerformAction(sender, sig, data, value);
      return true; // canPerform; && !bylaw.not
    }

    if (bylaw.bylawType == BylawType.Voting) {}

    if (bylaw.bylawType == BylawType.Combinator) {
      return negateIfNeeded(computeCombinatorBylaw(bylaw, sender, data, token, value), bylaw.not);
    }
  }

  function computeCombinatorBylaw(Bylaw storage bylaw, address sender, bytes data, address token, uint256 value) internal returns (bool) {
    bool leftResult = canPerformAction(bylaw.combinator.leftBylawId, sender, data, token, value);

    // shortcuts
    if (leftResult && bylaw.combinator.combinatorType == CombinatorType.Or) return true;
    if (!leftResult && bylaw.combinator.combinatorType == CombinatorType.And) return false;

    bool rightResult = canPerformAction(bylaw.combinator.rightBylawId, sender, data, token, value);

    // For or and, this always finishes the execution
    if (!rightResult && bylaw.combinator.combinatorType == CombinatorType.Or) return false;
    if (rightResult && bylaw.combinator.combinatorType == CombinatorType.And) return true;

    // redundant as and/or where solved already
    if (bylaw.combinator.combinatorType == CombinatorType.Xor) {
      return (leftResult && !rightResult) || (!leftResult && rightResult);
    }
  }

  function negateIfNeeded(bool result, bool negate) returns (bool) {
    return negate ? !result : result;
  }

  function isSpecialStatus(address entity, uint8 neededStatus) internal returns (bool) {
    return true;
  }

  function getStatus(address entity) internal returns (uint8) {
    return 1;
  }

  function checkVoting(VotingBylaw votingBylaw, address voteAddress) internal returns (bool) {
    IVotingApp votingApp = getVotingApp();
    var (,,, voteCreatedBlock, voteStartsBlock, voteEndsBlock, yays, nays, totalQuorum) = votingApp.getStatusForVoteAddress(voteAddress);

    // check votign timing is correct
    if (voteStartsBlock - voteCreatedBlock < votingBylaw.minimumDebateTime) return false;
    if (voteEndsBlock - voteStartsBlock < votingBylaw.minimumVotingTime) return false;

    uint256 quorum = yays + nays;
    uint256 yaysPct = yays * pctBase / quorum;
    uint256 quorumPct = quorum * pctBase / totalQuorum;

    return yaysPct >= votingBylaw.supportPct && quorumPct >= votingBylaw.minQuorumPct;
  }

  function getOwnershipApp() internal returns (OwnershipApp) {
    // gets the app address that can respond to getOrgToken
    return OwnershipApp(ApplicationOrgan(dao).getResponsiveApplicationForSignature(0xf594ba59));
  }

  function getVotingApp() internal returns (VotingApp) {
    // gets the app address that can respond to createVote
    return IVotingApp(ApplicationOrgan(dao).getResponsiveApplicationForSignature(0xad8c5d6e));
  }

  function getStatusApp() internal returns (StatusApp) {
    return StatusApp(ApplicationOrgan(dao).getResponsiveApplicationForSignature(0xad8c5d6e));
  }
  /*
  function getStatus(address entity) internal returns (uint8) {
    return StatusApp(app().dao()).entityStatus(entity);
  }

  function isSpecialStatus(address entity, uint8 neededStatus) internal returns (bool) {
    CapitalApp.SpecialEntityStatus status = CapitalApp.SpecialEntityStatus(neededStatus);

    if (status == CapitalApp.SpecialEntityStatus.Shareholder) {
      return CapitalApp(app().dao()).isHolder(entity);
    }

    if (status == CapitalApp.SpecialEntityStatus.StockSale) {
      return CapitalApp(app().dao()).isTokenSale(entity);
    }
  }

  function getStatusBylaw(string functionSignature) constant returns (uint8) {
    BylawsLib.Bylaw memory b = bylaws.getBylaw(functionSignature);

    if (b.status.enforced) return b.status.neededStatus;

    return uint8(255);
  }

  function getVotingBylaw(string functionSignature) constant returns (uint256 support, uint256 base, bool closingRelativeMajority, uint64 minimumVotingTime) {
    return getVotingBylaw(bytes4(sha3(functionSignature)));
  }

  function getVotingBylaw(bytes4 functionSignature) constant returns (uint256 support, uint256 base, bool closingRelativeMajority, uint64 minimumVotingTime) {
    BylawsLib.VotingBylaw memory b = bylaws.getBylaw(functionSignature).voting;

    if (!b.enforced) return;

    support = b.supportNeeded;
    base = b.supportBase;
    closingRelativeMajority = b.closingRelativeMajority;
    minimumVotingTime = b.minimumVotingTime;
  }


  function getAddressBylaw(string functionSignature) constant returns (address) {
    BylawsLib.AddressBylaw memory b = bylaws.getBylaw(functionSignature).addr;

    if (!b.enforced) return;

    return b.addr;
  }
  */
}
