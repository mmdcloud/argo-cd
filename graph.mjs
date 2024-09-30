import axios from 'axios'

export async function getUserDetails(accessToken) {
  try {
    const graphReq = {
      url: 'https://graph.microsoft.com/v1.0/me',
      headers: { Authorization: accessToken },
    }

    const resp = await axios(graphReq)
    return resp.data
  } catch (err) {
    console.log(`### 💥 ERROR! Failed to get user details ${err.toString()}`)
  }
}

export async function getUserPhoto(accessToken) {
  try {
    const graphReq = {
      url: 'https://graph.microsoft.com/v1.0/me/photo/$value',
      responseType: 'arraybuffer',
      headers: { Authorization: accessToken },
    }

    const resp = await axios(graphReq)
    return new Buffer.from(resp.data, 'binary').toString('base64')
  } catch (err) {
    console.log(`### 💥 ERROR! Failed to get user photo ${err.toString()}`)
  }
}
