import { drizzleConnect } from "drizzle-react";
import React, { Component, Fragment } from "react";
import PropTypes from "prop-types";
import moment from "moment";

import ContractData from "./ContractData";

import { getUSDValue } from "../Actions";

class PriceSection extends Component {
    constructor(props, context) {
      super();
      this.utils = context.drizzle.web3.utils;
      this.contracts = context.drizzle.contracts;
      this.state = {
        USD: -1,
        artworkPriceKey: context.drizzle.contracts.Harber.methods.price.cacheCall(),
        patron: null,
        patronKey: context.drizzle.contracts.ERC721Full.methods.ownerOf.cacheCall(0),
        timeAcquiredKey: context.drizzle.contracts.Harber.methods.timeAcquired.cacheCall(0),
        timeHeldKey: null,
        currentTimeHeld: 0,
        currentTimeHeldHumanized: ""
      };
    }

    async updateUSDPrice(props) {
      const price = this.utils.fromWei(this.getArtworkPrice(props), 'ether');
      const USD = await getUSDValue(price);
      this.setState({USD});
    }

    async updateTimeHeld(props, timeHeldKey) {
      const date = new Date();
      let currentTimeHeld = parseInt(this.getTimeHeld(props, timeHeldKey)) + (parseInt(date.getTime()/1000) - parseInt(this.getTimeAcquired(props)));

      /*
      note: this is a hack. smart contract didn't store timeAcquired when steward started. 
      Thus: time held will be very large. It needs to be reduced.
      */
      if (props.contracts['ERC721Full']['ownerOf'][this.state.patronKey].value === this.contracts.Harber.address) {
        const deployedtime = new this.utils.BN('1553202847');
        currentTimeHeld = new this.utils.BN(currentTimeHeld).sub(deployedtime).toString();
      }

      const currentTimeHeldHumanized = moment.duration(currentTimeHeld, 'seconds').humanize();
      this.setState({
        currentTimeHeld,
        currentTimeHeldHumanized,
      });
    }

    async updatePatron(props) {
      const patron = this.getPatron(props);
      // update timeHeldKey IF owner updated
      const timeHeldKey = this.contracts.Harber.methods.timeHeld.cacheCall(patron);
      this.setState({
        currentTimeHeld: 0,
        timeHeldKey,
        patron
      });
    }

    getArtworkPrice(props) {
      return new this.utils.BN(props.contracts['Harber']['getPrice']['0x0'][0].value);
    }

    getPatron(props) {
      return props.contracts['ERC721Full']['ownerOf'][0][this.state.patronKey].value;
    }

    getTimeAcquired(props) {
      return props.contracts['Harber']['timeAcquired'][this.state.timeAcquiredKey].value;
    }

    getTimeHeld(props, timeHeldKey) {
      return props.contracts['Harber']['timeHeld'][timeHeldKey].value;
    }

    async componentWillUpdate(nextProps, nextState) {
      if (this.state.patronKey in this.props.contracts['ERC721Full']['ownerOf']
      && this.state.patronKey in nextProps.contracts['ERC721Full']['ownerOf']) {
        if(this.getPatron(this.props) !== this.getPatron(nextProps) || this.state.patron === null) {
          this.updatePatron(nextProps);
        }
      }

      /* todo: fetch new exchange rate? */
      if (this.state.artworkPriceKey in this.props.contracts['Harber']['price']
      && this.state.artworkPriceKey in nextProps.contracts['Harber']['price']) {
        if (!this.getArtworkPrice(this.props).eq(this.getArtworkPrice(nextProps)) || this.state.USD === -1) {
          await this.updateUSDPrice(nextProps);
        }
      }

      if(this.state.timeHeldKey in this.props.contracts['Harber']['timeHeld']
      && this.state.timeHeldKey in nextProps.contracts['Harber']['timeHeld']) {
        if(this.getTimeHeld(this.props, this.state.timeHeldKey) !== this.getTimeHeld(nextProps, this.state.timeHeldKey) || this.state.currentTimeHeld === 0) {
          this.updateTimeHeld(nextProps, this.state.timeHeldKey);
        }
      }
    }

    render() {
      return (
        <Fragment>
        <h2>Valued at: <ContractData contract="Harber" method="getPrice" methodArgs={[0]} toEth /> ETH (~${this.state.USD} USD) </h2>
        Current Owner: <ContractData contract="ERC721Full" method="ownerOf" methodArgs={[0]}/><br />
        Total Time Held: {this.state.currentTimeHeldHumanized} 
        </Fragment>
      )
    }
}

PriceSection.contextTypes = {
  drizzle: PropTypes.object,
};

PriceSection.propTypes = {
};

/*
 * Export connected component.
 */

const mapStateToProps = state => {
  return {
    accounts: state.accounts,
    contracts: state.contracts,
    drizzleStatus: state.drizzleStatus,
    web3: state.web3,
  };
};

export default drizzleConnect(PriceSection, mapStateToProps);
