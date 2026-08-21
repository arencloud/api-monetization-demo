import { UserIdentity } from '@backstage/core-components';
import {
  configApiRef,
  SignInPageProps,
  useAnalytics,
  useApi,
} from '@backstage/core-plugin-api';
import {
  Box,
  Button,
  CircularProgress,
  Divider,
  Typography,
} from '@material-ui/core';
import { makeStyles } from '@material-ui/core/styles';
import AccountTreeOutlinedIcon from '@material-ui/icons/AccountTreeOutlined';
import ArrowForwardIcon from '@material-ui/icons/ArrowForward';
import AssessmentOutlinedIcon from '@material-ui/icons/AssessmentOutlined';
import CheckCircleOutlineIcon from '@material-ui/icons/CheckCircleOutline';
import VpnKeyOutlinedIcon from '@material-ui/icons/VpnKeyOutlined';
import React, { useCallback, useEffect, useState } from 'react';
import { useSearchParams } from 'react-router-dom';
import { oidcAuthApiRef } from '../apis';

const useStyles = makeStyles(theme => ({
  root: {
    background: '#f5f5f5',
    color: '#151515',
    display: 'grid',
    gridTemplateColumns: 'minmax(0, 1.2fr) minmax(420px, 0.8fr)',
    minHeight: '100vh',
    width: '100%',
    [theme.breakpoints.down('sm')]: {
      display: 'block',
    },
  },
  hero: {
    alignItems: 'stretch',
    background:
      'radial-gradient(circle at 82% 18%, rgba(238, 0, 0, 0.28), transparent 27%), linear-gradient(145deg, #151515 0%, #1f1f1f 58%, #292929 100%)',
    color: '#fff',
    display: 'flex',
    flexDirection: 'column',
    justifyContent: 'space-between',
    minHeight: '100vh',
    overflow: 'hidden',
    padding: 'clamp(32px, 5vw, 80px)',
    position: 'relative',
    '&::before': {
      border: '1px solid rgba(255, 255, 255, 0.08)',
      borderRadius: '50%',
      content: '""',
      height: 520,
      position: 'absolute',
      right: -240,
      top: -235,
      width: 520,
    },
    '&::after': {
      background: '#ee0000',
      bottom: 0,
      content: '""',
      height: 6,
      left: 0,
      position: 'absolute',
      width: '42%',
    },
    [theme.breakpoints.down('sm')]: {
      minHeight: 'auto',
      padding: '32px 28px 44px',
    },
  },
  brand: {
    alignItems: 'center',
    display: 'flex',
    gap: 14,
    position: 'relative',
    zIndex: 1,
  },
  brandMark: {
    alignItems: 'center',
    background: '#ee0000',
    borderRadius: 8,
    boxShadow: '0 10px 28px rgba(0, 0, 0, 0.28)',
    display: 'flex',
    height: 48,
    justifyContent: 'center',
    width: 48,
  },
  brandBars: {
    display: 'grid',
    gap: 4,
    width: 24,
    '& span': {
      background: '#fff',
      display: 'block',
      height: 4,
    },
    '& span:nth-child(2)': {
      width: 16,
    },
  },
  brandTitle: {
    fontSize: 16,
    fontWeight: 700,
    letterSpacing: '0.01em',
    lineHeight: 1.15,
  },
  brandSubtitle: {
    color: '#b8bbbe',
    fontSize: 12,
    letterSpacing: '0.08em',
    marginTop: 3,
    textTransform: 'uppercase',
  },
  heroContent: {
    margin: '72px 0 64px',
    maxWidth: 820,
    position: 'relative',
    zIndex: 1,
    [theme.breakpoints.down('sm')]: {
      margin: '52px 0 12px',
    },
  },
  eyebrow: {
    alignItems: 'center',
    color: '#f56a6a',
    display: 'flex',
    fontSize: 12,
    fontWeight: 700,
    gap: 12,
    letterSpacing: '0.13em',
    marginBottom: 20,
    textTransform: 'uppercase',
    '&::before': {
      background: '#ee0000',
      content: '""',
      height: 3,
      width: 28,
    },
  },
  headline: {
    fontSize: 'clamp(48px, 5vw, 80px)',
    fontWeight: 700,
    letterSpacing: '-0.045em',
    lineHeight: 0.98,
    marginBottom: 28,
    maxWidth: 760,
    [theme.breakpoints.down('xs')]: {
      fontSize: 43,
    },
  },
  lead: {
    color: '#d2d2d2',
    fontSize: 19,
    lineHeight: 1.6,
    maxWidth: 680,
  },
  featureGrid: {
    display: 'grid',
    gap: 14,
    gridTemplateColumns: 'repeat(3, minmax(0, 1fr))',
    marginTop: 50,
    [theme.breakpoints.down('md')]: {
      gridTemplateColumns: '1fr',
    },
    [theme.breakpoints.down('sm')]: {
      display: 'none',
    },
  },
  feature: {
    background: 'rgba(255, 255, 255, 0.055)',
    border: '1px solid rgba(255, 255, 255, 0.1)',
    borderRadius: 8,
    minHeight: 136,
    padding: '22px 20px',
  },
  featureIcon: {
    color: '#f56a6a',
    fontSize: 25,
    marginBottom: 14,
  },
  featureTitle: {
    fontSize: 15,
    fontWeight: 700,
    marginBottom: 7,
  },
  featureCopy: {
    color: '#b8bbbe',
    fontSize: 13,
    lineHeight: 1.45,
  },
  heroFooter: {
    color: '#8a8d90',
    fontSize: 12,
    letterSpacing: '0.02em',
    position: 'relative',
    zIndex: 1,
    [theme.breakpoints.down('sm')]: {
      display: 'none',
    },
  },
  signInPanel: {
    alignItems: 'center',
    background:
      'linear-gradient(180deg, #fff 0%, #f7f7f7 68%, #efefef 100%)',
    display: 'flex',
    justifyContent: 'center',
    minHeight: '100vh',
    padding: '48px clamp(28px, 5vw, 76px)',
    position: 'relative',
    [theme.breakpoints.down('sm')]: {
      minHeight: 'auto',
      padding: '48px 24px 64px',
    },
  },
  signInCard: {
    maxWidth: 460,
    width: '100%',
  },
  portalLabel: {
    color: '#c9190b',
    fontSize: 12,
    fontWeight: 700,
    letterSpacing: '0.12em',
    marginBottom: 16,
    textTransform: 'uppercase',
  },
  welcome: {
    fontSize: 'clamp(34px, 3vw, 48px)',
    fontWeight: 700,
    letterSpacing: '-0.035em',
    lineHeight: 1.08,
    marginBottom: 18,
  },
  welcomeCopy: {
    color: '#4f5255',
    fontSize: 16,
    lineHeight: 1.6,
    marginBottom: 32,
  },
  divider: {
    margin: '0 0 30px',
  },
  signInButton: {
    background: '#ee0000',
    borderRadius: 4,
    boxShadow: '0 8px 22px rgba(238, 0, 0, 0.2)',
    color: '#fff',
    fontSize: 15,
    fontWeight: 700,
    minHeight: 54,
    padding: '13px 20px',
    textTransform: 'none',
    '&:hover': {
      background: '#a30000',
      boxShadow: '0 10px 26px rgba(163, 0, 0, 0.26)',
    },
    '&:focus-visible': {
      outline: '3px solid #0066cc',
      outlineOffset: 3,
    },
    '&.Mui-disabled': {
      background: '#d2d2d2',
      color: '#6a6e73',
    },
  },
  helper: {
    color: '#6a6e73',
    fontSize: 13,
    lineHeight: 1.5,
    marginTop: 14,
  },
  error: {
    background: '#faeae8',
    borderLeft: '4px solid #c9190b',
    color: '#7d1007',
    fontSize: 13,
    lineHeight: 1.5,
    marginBottom: 22,
    padding: '14px 16px',
  },
  trust: {
    borderTop: '1px solid #d2d2d2',
    marginTop: 40,
    paddingTop: 24,
  },
  trustItem: {
    alignItems: 'flex-start',
    color: '#4f5255',
    display: 'flex',
    fontSize: 13,
    gap: 10,
    lineHeight: 1.45,
    marginBottom: 13,
  },
  trustIcon: {
    color: '#3e8635',
    fontSize: 18,
    marginTop: 1,
  },
  poweredBy: {
    color: '#8a8d90',
    fontSize: 11,
    letterSpacing: '0.04em',
    marginTop: 32,
    textTransform: 'uppercase',
  },
}));

const capabilityCards = [
  {
    icon: VpnKeyOutlinedIcon,
    title: 'Subscribe securely',
    copy: 'Use managed API keys or short-lived Keycloak JWTs.',
  },
  {
    icon: AccountTreeOutlinedIcon,
    title: 'Build on a Golden Path',
    copy: 'Create governed APIs with GitOps and OpenShift Dev Spaces.',
  },
  {
    icon: AssessmentOutlinedIcon,
    title: 'Turn usage into value',
    copy: 'Understand plans, consumption, invoices and projected revenue.',
  },
];

export const CustomSignInPage = ({ onSignInSuccess }: SignInPageProps) => {
  const classes = useStyles();
  const analytics = useAnalytics();
  const authApi = useApi(oidcAuthApiRef);
  const configApi = useApi(configApiRef);
  const [searchParams] = useSearchParams();
  const forwardedError = searchParams.get('error');
  const [checkingSession, setCheckingSession] = useState(true);
  const [signingIn, setSigningIn] = useState(false);
  const [error, setError] = useState<Error>();

  const completeSignIn = useCallback(async (interactive: boolean) => {
    let completed = false;
    if (interactive) {
      setSigningIn(true);
      setError(undefined);
    }

    try {
      const identityResponse = await authApi.getBackstageIdentity(
        interactive ? { instantPopup: true } : { optional: true },
      );
      if (!identityResponse) {
        if (interactive) {
          throw new Error('Red Hat build of Keycloak did not return a Developer Hub identity.');
        }
        return;
      }

      const profile = await authApi.getProfile();
      completed = true;
      analytics.captureEvent('signIn', 'success');
      onSignInSuccess(UserIdentity.create({
        identity: identityResponse.identity,
        authApi,
        profile,
      }));
    } catch (caught) {
      const signInError = caught instanceof Error ? caught : new Error(String(caught));
      if (signInError.name !== 'PopupRejectedError') {
        setError(signInError);
      }
    } finally {
      if (interactive && !completed) {
        setSigningIn(false);
      }
    }
  }, [analytics, authApi, onSignInSuccess]);

  useEffect(() => {
    if (forwardedError) {
      setError(new Error(forwardedError));
    }

    let active = true;
    void completeSignIn(false).finally(() => {
      if (active) setCheckingSession(false);
    });
    return () => {
      active = false;
    };
  }, [completeSignIn, forwardedError]);

  const iconLogo = configApi.getOptionalString('app.branding.iconLogo');
  const appTitle = configApi.getOptionalString('app.title') ?? 'API Monetization Developer Hub';

  return (
    <main className={classes.root} aria-label={`${appTitle} sign in`}>
      <section className={classes.hero} aria-labelledby="api-monetization-welcome">
        <Box className={classes.brand}>
          {iconLogo ? (
            <img className={classes.brandMark} src={iconLogo} alt="" aria-hidden="true" />
          ) : (
            <Box className={classes.brandMark} aria-hidden="true">
              <Box className={classes.brandBars}>
                <span />
                <span />
                <span />
              </Box>
            </Box>
          )}
          <Box>
            <div className={classes.brandTitle}>API Monetization</div>
            <div className={classes.brandSubtitle}>Developer Hub</div>
          </Box>
        </Box>

        <Box className={classes.heroContent}>
          <div className={classes.eyebrow}>Red Hat Connectivity Link · OpenShift</div>
          <Typography id="api-monetization-welcome" component="h1" className={classes.headline}>
            APIs become products.
          </Typography>
          <Typography component="p" className={classes.lead}>
            One governed workspace to discover APIs, manage subscriptions, build new interfaces,
            and connect real usage to commercial plans.
          </Typography>

          <Box className={classes.featureGrid}>
            {capabilityCards.map(({ icon: Icon, title, copy }) => (
              <Box className={classes.feature} key={title}>
                <Icon className={classes.featureIcon} />
                <div className={classes.featureTitle}>{title}</div>
                <div className={classes.featureCopy}>{copy}</div>
              </Box>
            ))}
          </Box>
        </Box>

        <div className={classes.heroFooter}>
          Connectivity Link · Service Mesh · OpenShift AI · GitOps · OpenTelemetry
        </div>
      </section>

      <section className={classes.signInPanel} aria-labelledby="sign-in-title">
        <Box className={classes.signInCard} aria-busy={checkingSession || signingIn}>
          <div className={classes.portalLabel}>Secure developer portal</div>
          <Typography id="sign-in-title" component="h2" className={classes.welcome}>
            Welcome to your API economy.
          </Typography>
          <Typography component="p" className={classes.welcomeCopy}>
            Continue with the API Monetization identity service. Your role determines the catalog,
            subscription, billing and API-owner capabilities available after sign-in.
          </Typography>

          <Divider className={classes.divider} />

          {error && (
            <Box className={classes.error} role="alert">
              <strong>Unable to sign in.</strong><br />
              {error.message}
            </Box>
          )}

          <Button
            className={classes.signInButton}
            disabled={checkingSession || signingIn}
            endIcon={checkingSession || signingIn ? <CircularProgress size={18} /> : <ArrowForwardIcon />}
            fullWidth
            onClick={() => void completeSignIn(true)}
            variant="contained"
          >
            {checkingSession
              ? 'Checking your session…'
              : signingIn
                ? 'Opening secure sign-in…'
                : 'Continue with Keycloak'}
          </Button>
          <Typography component="p" className={classes.helper}>
            New consumer? Continue to register. API-owner access is granted through the reviewed
            onboarding workflow after your account is created.
          </Typography>

          <Box className={classes.trust}>
            <div className={classes.trustItem}>
              <CheckCircleOutlineIcon className={classes.trustIcon} />
              <span>Single sign-on backed by Red Hat build of Keycloak</span>
            </div>
            <div className={classes.trustItem}>
              <CheckCircleOutlineIcon className={classes.trustIcon} />
              <span>API credentials and billing data remain subject-scoped</span>
            </div>
          </Box>

          <div className={classes.poweredBy}>Powered by Red Hat Developer Hub</div>
        </Box>
      </section>
    </main>
  );
};
